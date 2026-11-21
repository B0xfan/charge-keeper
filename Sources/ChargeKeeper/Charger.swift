// Limits under 80%. macOS refuses its own limit below 80 (tested 2026-10-27), so under 80 Charge Keeper keeps the Mac's limit
// at 80 as a backstop and switches the charger's power off at the chosen limit and back on `cutBand` points lower. The switch is
// an SMC key (chargerKeys; on an M2 CHIE, the same switch batt's adapter mode and AlDente's discharge use). Writing it needs
// root, so a small helper does it: this program with --helper, started by launchd as root (scripts/install-helper.sh).
// The helper owns the safety: power goes back on when the app's connection closes (quit, crash, force-quit), when the app
// stops checking in (hung), before sleep, at the helper's own start (boot, or a restart after it died), on a stop signal,
// at a hard battery floor, and from a dead-man thread if its own queue stops (it tries, then exits so launchd starts a fresh one).
// A cut it did not make (AlDente's) is never touched. shortcut: the chip has one switch, so an AlDente cut made in the same moment
// ours is given back is undone with it; the app gives ours back as soon as AlDente starts, which keeps that window to a moment.
import Foundation
import IOKit
import IOKit.pwr_mgt
import AppKit

let macFloor = 80   // the lowest level the Mac's own limit accepts
let cutBand = 5     // power back on this many points under the limit: the same gap macOS itself leaves above 80
let helperSocket = "/var/run/com.johnhesch.keeper.helper.sock"
let helperMarker = "/var/db/com.johnhesch.keeper.helper.cut"  // exists exactly while a cut of ours may be on; survives a restart
let powerOn: UInt8 = 0x00, powerOff: UInt8 = 0x08
let cmdCut = UInt8(ascii: "c"), cmdOn = UInt8(ascii: "o")
// A cut for the calibration cycle's run down: the battery floor is deepFloor instead of 40 (calibFloor stops it before that).
let cmdDeep = UInt8(ascii: "d"), deepFloor = 10
// Mockup v3 extras: low power mode on/off, MagSafe light dark/normal. A helper older than these treats any unknown byte as
// "power on" and answers O or B, never replyDone, which is how the app tells it needs the helper updated.
let cmdLowOn = UInt8(ascii: "L"), cmdLowOff = UInt8(ascii: "l"), cmdLedDark = UInt8(ascii: "x"), cmdLedNormal = UInt8(ascii: "y")
// Replies: we switched it off / power is on / off by another app, left alone / the switch failed / an extra was done.
let replyCut = UInt8(ascii: "C"), replyOn = UInt8(ascii: "O"), replyBusy = UInt8(ascii: "B"), replyErr = UInt8(ascii: "E"), replyDone = UInt8(ascii: "Y")
let ledSystem: UInt8 = 0x00, ledOff: UInt8 = 0x01  // the SMC key ACLC (MagSafe light): 0 = macOS decides, 1 = off (as batt uses it)

// Mockup v4, Intel Macs: macOS has no built-in limit there, so the helper writes the SMC charge-limit key BCLM (a percent,
// 100 = no limit; public facts from the bclm tool's README: Intel only, and the Mac charges about 3 points past it). One byte per
// limit, cmdLimitBase + percent; 100 gives the limit back. An older helper reads these bytes as "power on" (answers O or B, never Y).
let cmdLimitBase: UInt8 = 0x80, noLimit: UInt8 = 100
let helperLimitMarker = "/var/db/com.johnhesch.keeper.helper.limit"  // exists exactly while a limit of ours may be on
func limitCommand(_ v: Int) -> UInt8 { cmdLimitBase + UInt8(clampLimit(v)) }
func limitValue(_ c: UInt8) -> UInt8? { c >= cmdLimitBase + UInt8(limitRange.lowerBound) && c <= cmdLimitBase + noLimit ? c - cmdLimitBase : nil }
// Apple chips or Intel, as the hardware is (a copy under Rosetta still counts as an Apple chip).
let intelMac: Bool = { var v: Int32 = 0, n = MemoryLayout<Int32>.size; return sysctlbyname("hw.optional.arm64", &v, &n, nil, 0) != 0 || v == 0 }()

// Heat pause, fixed points in °F: pause above 95, start again at 91 or cooler.
let heatPauseF = 95.0, heatResumeF = 91.0
let heatFloor = 50  // at or under this level heat pause ends: under 80 a pause runs the Mac on its battery

// nil: not paused. Paused: the level it stopped at, only ever moving down, so a small dip is not charged back up while warm.
// An unreadable temperature ends the pause (never a pause nobody can see the reason for). At the floor the pause ends, and a
// new one starts only 5 above it, so a warm battery near 50% is not switched on and off at every percent.
func heatStep(on: Bool, tempF: Double?, level: Int, pausedAt: Int?) -> Int? {
    guard on, let t = tempF, level > heatFloor, pausedAt == nil ? t > heatPauseF && level > heatFloor + cutBand : t > heatResumeF else { return nil }
    return min(pausedAt ?? level, level)
}

// Where charging starts again after the top was reached: the sailing range's bottom, else 5 under a limit below 80
// (the charger switch's gap), else nowhere (80 and up, macOS's own limit does its own gap).
// floor: the lowest limit the Mac holds by itself (macFloor; 0 on Intel, where BCLM holds any limit).
func restBottom(limit: Int, sailing: Bool, bottom: Int, floor: Int = macFloor) -> Int? { sailing ? bottom : limit < floor ? limit - cutBand : nil }
// Resting: the top was reached and the level has not yet come down to the bottom. shortcut: kept in memory only, so after a
// restart it charges up to the top once before resting again.
func nextResting(level: Int, top: Int, bottom: Int?, resting: Bool) -> Bool {
    guard let b = bottom else { return false }
    return level >= top ? true : level <= b ? false : resting
}

// mac: the Mac's own limit (80...100), nil = off (charge to full once). cut: the charger's power switched off.
struct Plan: Equatable { var mac: Int?; var cut: Bool }
func plan(level: Int, limit: Int, bottom: Int?, resting: Bool, fullOnce: Bool, pausedAt: Int?, floor: Int = macFloor) -> Plan {
    var r = Plan(mac: fullOnce ? nil : max(limit, floor), cut: false)
    // Resting: the Mac's limit at the bottom (on the charger the level then stays put); a bottom under 80 needs the charger
    // switch from the top down, as the Mac's own 80 would never let it lower.
    if !fullOnce, resting, let b = bottom { r = Plan(mac: max(b, floor), cut: b < floor) }
    // Heat wins over everything, "Charge to full once" too: stop at the level it paused at.
    if let p = pausedAt { r = Plan(mac: max(min(r.mac ?? 100, p), floor), cut: r.cut || level < floor) }
    return r
}

func lidClosed() -> Bool {
    let root = IOServiceGetMatchingService(0, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
}

// Any AlDente edition. Its root helper is a daemon, not listed here.
func aldenteRunning() -> Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("com.apphousekitchen.aldente") == true } }

// MARK: - the switch

protocol ChargerSwitch: AnyObject { func read() -> UInt8?; func write(_ v: UInt8) -> Bool }

// The charger switch differs by firmware (batt's adapter keys): CHIE (off 0x08) on an M2 since macOS 26, CH0I or CH0J
// (off 0x01) on Apple chips with older firmware. On Intel, CH0I is the force-discharge key (off 0x01; the same key in the Linux
// and OpenBSD Apple SMC drivers), which the run down uses there.
let chargerKeys: [(key: String, off: UInt8)] = [("CHIE", 0x08), ("CH0I", 0x01), ("CH0J", 0x01)]
func fromChip(_ raw: UInt8, off: UInt8?) -> UInt8 { off == nil ? raw : raw == 0 ? powerOn : powerOff }  // charger keys: any non-zero byte is off (another app may use its own)
func toChip(_ v: UInt8, off: UInt8?) -> UInt8 { off.map { v == powerOff ? $0 : v } ?? v }
func chargerSwitch() -> SMCSwitch? { chargerKeys.lazy.compactMap { SMCSwitch(key: $0.key, off: $0.off) }.first }

// One 1-byte SMC key (CHIE: the charger switch, ACLC: the MagSafe light). Request layout: key@0, dataSize@28, result@40, command@42, bytes@48 (5 read, 6 write, 9 key info).
final class SMCSwitch: ChargerSwitch {
    private var conn: io_connect_t = 0
    let key: String
    private let off: UInt8?  // charger keys: the chip's "off" byte, shown to the helper as powerOff whatever the key
    init?(key: String, off: UInt8? = nil) {
        self.key = key; self.off = off
        let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        // Never write a key whose size is not 1 byte. A failed look ends the helper; launchd starts it again.
        guard let i = call(9), i[28] == 1, i[29] == 0, i[30] == 0, i[31] == 0 else { return nil }  // deinit closes conn
    }
    deinit { IOServiceClose(conn) }
    private func call(_ cmd: UInt8, _ value: UInt8? = nil) -> [UInt8]? {
        var b = [UInt8](repeating: 0, count: 80)
        for (i, c) in key.utf8.enumerated() { b[3 - i] = c }  // the key as a little-endian 32-bit number
        b[28] = 1; b[42] = cmd
        if let value { b[48] = value }
        var out = [UInt8](repeating: 0, count: 80), size = 80
        let rc = b.withUnsafeBytes { i in out.withUnsafeMutableBytes { o in IOConnectCallStructMethod(conn, 2, i.baseAddress, 80, o.baseAddress, &size) } }
        return rc == KERN_SUCCESS && out[40] == 0 ? out : nil
    }
    func read() -> UInt8? { call(5).map { fromChip($0[48], off: off) } }
    func write(_ v: UInt8) -> Bool { call(6, toChip(v, off: off)) != nil }
}

// A Mac with BCLM but no charger key: every cut is refused (an error), the limit still works.
final class NoSwitch: ChargerSwitch { func read() -> UInt8? { nil }; func write(_ v: UInt8) -> Bool { false } }

// MARK: - the helper's rules (one queue; pure apart from the switch and the marker file)

// The marker goes down (and to disk, with its folder entry) before the switch, so a crash at any later point is undone at the next start.
func writeMarker(_ path: String) -> Bool {
    let f = open(path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o600)
    guard f >= 0 else { return false }
    let d = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_CLOEXEC)  // the folder entry too, or a crash can lose the file
    let synced = fsync(f) == 0 && d >= 0 && fsync(d) == 0
    close(f); if d >= 0 { close(d) }
    if !synced { unlink(path) }
    return synced
}

final class ChargerGuard {
    let sw: ChargerSwitch, marker: String, lease: TimeInterval, floor: Int
    private(set) var ownCut = false
    private var deep = false  // the cut was asked with cmdDeep: the floor is deepFloor
    private var owner: Int32 = -1          // the connection that asked for the cut; its closing switches power back on
    private var renewed: TimeInterval = 0  // when the owner last checked in
    init(_ sw: ChargerSwitch, marker: String, lease: TimeInterval = 150, floor: Int = 40) {
        self.sw = sw; self.marker = marker; self.lease = lease; self.floor = floor
        restore()  // boot, or a restart after the helper died: a cut of ours (the marker says so) is undone first
    }
    private var markerExists: Bool { access(marker, F_OK) == 0 }

    func command(_ c: UInt8, fd: Int32, now: TimeInterval) -> UInt8 {
        guard c == cmdCut || c == cmdDeep else { return !restore() ? replyErr : sw.read() == powerOff ? replyBusy : replyOn }
        owner = fd; renewed = now; deep = c == cmdDeep
        if !ownCut && markerExists { ownCut = true }  // a power-on still owed: the cut is ours, so it is simply kept
        if !ownCut {
            guard let v = sw.read() else { return replyErr }
            guard v == powerOn else { return replyBusy }  // another app switched it off: not ours to take or give back
            guard writeMarker(marker) else { return replyErr }
            ownCut = true
        }
        if sw.read() == powerOff { return replyCut }  // already off; also re-done if the Mac switched it back on by itself
        if sw.write(powerOff), sw.read() == powerOff { return replyCut }
        restore()
        return replyErr
    }

    func closed(_ fd: Int32) { if fd == owner { owner = -1; restore() } }
    func willSleep() { restore() }
    // Every few seconds. Level nil (unreadable) counts as under the floor.
    func tick(now: TimeInterval, level: Int?) {
        if !ownCut && !markerExists { return }
        if !ownCut || now - renewed > lease || (level ?? 0) <= (deep ? deepFloor : floor) { restore() }  // !ownCut with a marker: a power-on still owed
    }

    // Power back on, if the cut is ours. Checked by reading. On failure the marker stays, so the next tick tries again.
    @discardableResult func restore() -> Bool {
        guard ownCut || markerExists else { return true }  // nothing of ours: never touch another app's setting
        ownCut = false; deep = false
        guard sw.write(powerOn), sw.read() == powerOn else { return false }
        unlink(marker)
        return true
    }
}

// Intel's charge limit (BCLM), owned by the app's connection like a cut: given back (100) when that connection closes (quit,
// crash, force-quit), when the app stops checking in, on a stop signal and at the helper's own start. Not before sleep: the
// limit only stops charging, so holding it while asleep is safe, unlike a cut. A limit set by another app is never touched.
final class LimitGuard {
    let sw: ChargerSwitch?, marker: String, lease: TimeInterval
    private var owner: Int32 = -1, renewed: TimeInterval = 0
    init(_ sw: ChargerSwitch?, marker: String, lease: TimeInterval = 150) { self.sw = sw; self.marker = marker; self.lease = lease; restore() }
    private var markerExists: Bool { access(marker, F_OK) == 0 }
    // nil: not a limit byte.
    func command(_ c: UInt8, fd: Int32, now: TimeInterval) -> UInt8? {
        guard let v = limitValue(c) else { return nil }
        guard let sw else { return replyErr }  // no BCLM key (Apple chips)
        if v == noLimit { owner = -1; return restore() ? replyDone : replyErr }
        if !markerExists {
            guard let cur = sw.read() else { return replyErr }
            guard cur == noLimit else { return replyBusy }  // another app's limit: not ours to take or give back
            guard writeMarker(marker) else { return replyErr }
        }
        owner = fd; renewed = now
        if sw.read() == v || sw.write(v) && sw.read() == v { return replyDone }
        restore()
        return replyErr
    }
    func closed(_ fd: Int32) { if fd == owner { owner = -1; restore() } }
    func tick(now: TimeInterval) { if markerExists && (owner < 0 || now - renewed > lease) { owner = -1; restore() } }
    // Back to no limit, if the limit is ours. Checked by reading; on failure the marker stays and the next tick tries again.
    @discardableResult func restore() -> Bool {
        guard markerExists, let sw else { return true }
        guard sw.write(noLimit), sw.read() == noLimit else { return false }
        unlink(marker)
        return true
    }
}

// Low power mode and the MagSafe light, for the app (mockup v3). The light goes back to normal when the connection that
// darkened it closes (quit, crash, kill) and when the helper stops. shortcut: a helper that dies outright leaves the light
// dark until the app asks again or the Mac restarts; it is only a light, so no marker file like the cut's.
final class Extras {
    let led: ChargerSwitch?
    let lowPower: (Bool) -> Bool
    private var ledOwner: Int32 = -1
    init(led: ChargerSwitch?, lowPower: @escaping (Bool) -> Bool) { self.led = led; self.lowPower = lowPower }
    // nil: not an extra (the charger switch's command).
    func command(_ c: UInt8, fd: Int32) -> UInt8? {
        switch c {
        case cmdLowOn, cmdLowOff: return lowPower(c == cmdLowOn) ? replyDone : replyErr
        case cmdLedDark, cmdLedNormal:
            let v = c == cmdLedDark ? ledOff : ledSystem
            guard let led, led.read() == v || led.write(v) else { return replyErr }
            ledOwner = c == cmdLedDark ? fd : -1
            return replyDone
        default: return nil
        }
    }
    func closed(_ fd: Int32) { if fd == ledOwner { reset() } }
    func reset() { if ledOwner >= 0 { ledOwner = -1; _ = led?.write(ledSystem) } }
}

// pmset is the Mac's own switch for low power mode; it needs root, which the helper has.
func setLowPower(_ on: Bool) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-a", "lowpowermode", on ? "1" : "0"]
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    guard (try? p.run()) != nil else { return false }
    // It runs on the helper's one queue, which also owns every power-back-on path: never wait long.
    guard done.wait(timeout: .now() + 5) == .success else { p.terminate(); return false }
    return p.terminationStatus == 0
}

// MARK: - the helper process

private func unixAddress(_ path: String) -> sockaddr_un? {
    var a = sockaddr_un()
    guard path.utf8.count < MemoryLayout.size(ofValue: a.sun_path) else { return nil }  // never a silently shortened path
    a.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &a.sun_path) { p in for (i, c) in path.utf8.enumerated() { p[i] = c } }
    return a
}
private func noSigpipeCloexec(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))  // a write to a dead peer must not kill us
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)  // the app's watchdog must not inherit the connection and keep it open after the app dies
}

// Listens on `path`; only `uid` (the user) and root may talk to it. One serial queue owns the guard.
final class HelperServer {
    let g: ChargerGuard, q: DispatchQueue, uid: uid_t, extras: Extras, limits: LimitGuard?
    private var listener: DispatchSourceRead?
    private var conns: [Int32: DispatchSourceRead] = [:]  // queue only
    init(_ g: ChargerGuard, queue: DispatchQueue, uid: uid_t, extras: Extras = Extras(led: nil, lowPower: { _ in false }), limits: LimitGuard? = nil) {
        self.g = g; q = queue; self.uid = uid; self.extras = extras; self.limits = limits
    }

    func start(path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        noSigpipeCloexec(s)
        guard var a = unixAddress(path) else { close(s); return false }
        unlink(path)
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        guard bound, chmod(path, 0o666) == 0, listen(s, 4) == 0 else { close(s); return false }  // 0666: the peer check below is the gate
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: q)
        src.setEventHandler { [weak self] in self?.accept(s) }
        src.resume()
        listener = src
        return true
    }

    private func accept(_ s: Int32) {
        let c = Darwin.accept(s, nil, nil)
        guard c >= 0 else { return }
        var pu: uid_t = 0, pg: gid_t = 0
        guard getpeereid(c, &pu, &pg) == 0, pu == uid || pu == 0 else { close(c); return }
        noSigpipeCloexec(c)
        let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: q)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 16)
            let n = read(c, &buf, buf.count)
            guard n > 0 else { self.conns[c]?.cancel(); return }  // closed: the app quit, crashed or was killed
            for b in buf[0..<n] {
                let now = ProcessInfo.processInfo.systemUptime
                var r = self.extras.command(b, fd: c) ?? self.limits?.command(b, fd: c, now: now) ?? self.g.command(b, fd: c, now: now)
                _ = write(c, &r, 1)
            }
        }
        src.setCancelHandler { [weak self] in self?.g.closed(c); self?.extras.closed(c); self?.limits?.closed(c); self?.conns[c] = nil; close(c) }  // before close(): the fd number may be reused once closed
        conns[c] = src
        src.resume()
    }
}

// When the helper's queue last ran its timer; read by the dead-man thread.
final class Beat {
    private let l = NSLock()
    private var t = ProcessInfo.processInfo.systemUptime
    func set() { l.lock(); t = ProcessInfo.processInfo.systemUptime; l.unlock() }
    var age: TimeInterval { l.lock(); defer { l.unlock() }; return ProcessInfo.processInfo.systemUptime - t }
}

private var sleepGuard: ChargerGuard?
private var rootPort: io_connect_t = 0

// File-backed stand-in for the SMC key, for testing the real helper process without root (--helper-fake <folder>).
final class FileSwitch: ChargerSwitch {
    let path: String
    init(_ path: String) { self.path = path }
    func read() -> UInt8? { (try? Data(contentsOf: URL(fileURLWithPath: path)))?.first ?? powerOn }
    func write(_ v: UInt8) -> Bool { (try? Data([v]).write(to: URL(fileURLWithPath: path))) != nil }
}

// --helper <uid>: the real thing (root, SMC). --helper-fake <folder>: same process, but the switch, socket and marker live in <folder>.
func runHelper(_ args: [String]) -> Never {
    let fake = args[1] == "--helper-fake"
    guard args.count == 3 else { exit(2) }
    let sw: ChargerSwitch, sock: String, marker: String, uid: uid_t, extras: Extras, bclm: ChargerSwitch?, limitMarker: String
    if fake {
        let dir = args[2]
        sw = FileSwitch(dir + "/switch"); sock = dir + "/helper.sock"; marker = dir + "/cut"; uid = getuid()
        extras = Extras(led: FileSwitch(dir + "/led"), lowPower: { on in (try? Data(on ? "1".utf8 : "0".utf8).write(to: URL(fileURLWithPath: dir + "/lowpower"))) != nil })
        if access(dir + "/bclm", F_OK) != 0 { _ = FileSwitch(dir + "/bclm").write(noLimit) }  // a fresh Intel Mac: no limit
        bclm = FileSwitch(dir + "/bclm"); limitMarker = dir + "/limit"
    } else {
        bclm = SMCSwitch(key: "BCLM")  // Intel only; none on Apple chips
        guard let u = uid_t(args[2]), let s: ChargerSwitch = chargerSwitch() ?? (bclm != nil ? NoSwitch() : nil) else { exit(1) }  // launchd starts it again
        sw = s; sock = helperSocket; marker = helperMarker; uid = u; limitMarker = helperLimitMarker
        extras = Extras(led: SMCSwitch(key: "ACLC"), lowPower: setLowPower)  // no ACLC key (no MagSafe): the light answers an error
    }
    signal(SIGPIPE, SIG_IGN)
    let q = DispatchQueue(label: "keeper.helper")
    let g = q.sync { ChargerGuard(sw, marker: marker) }
    let limits = q.sync { LimitGuard(bclm, marker: limitMarker) }
    let server = HelperServer(g, queue: q, uid: uid, extras: extras, limits: limits)
    guard q.sync(execute: { server.start(path: sock) }) else { exit(1) }

    // Before sleep: power back on (nothing watches while the Mac sleeps). Without this hook it must not run at all.
    sleepGuard = g
    var port: IONotificationPortRef? = nil
    var notifier: io_object_t = 0
    rootPort = IORegisterForSystemPower(nil, &port, { _, _, type, arg in
        guard type == 0xE000_0280 || type == 0xE000_0270 else { return }  // kIOMessageSystemWillSleep, kIOMessageCanSystemSleep
        if type == 0xE000_0280 { sleepGuard?.willSleep() }
        IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    }, &notifier)
    guard rootPort != 0, let port else { q.sync { _ = g.restore() }; exit(1) }
    IONotificationPortSetDispatchQueue(port, q)

    for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {  // launchd stops daemons with SIGTERM at shutdown and on removal
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: q)
        s.setEventHandler { g.restore(); limits.restore(); extras.reset(); exit(0) }
        s.resume()
        signalSources.append(s)
    }
    let beat = Beat()
    let t = DispatchSource.makeTimerSource(queue: q)
    t.schedule(deadline: .now() + 5, repeating: 5)
    t.setEventHandler { beat.set(); let now = ProcessInfo.processInfo.systemUptime; g.tick(now: now, level: battery().current); limits.tick(now: now) }
    t.resume()
    // Dead man: if the queue stops answering, try power-on from a spare thread (it may hang on the same chip call), then exit
    // regardless; launchd starts a fresh helper, whose start-up restore() tries again and reads it back.
    Thread.detachNewThread {
        while true {
            sleep(10)
            guard beat.age > 60 else { continue }
            Thread.detachNewThread { if access(marker, F_OK) == 0, sw.write(powerOn), sw.read() == powerOn { unlink(marker) } }
            Thread.detachNewThread { if access(limitMarker, F_OK) == 0, let b = bclm, b.write(noLimit), b.read() == noLimit { unlink(limitMarker) } }
            sleep(2)
            _exit(1)
        }
    }
    withExtendedLifetime((server, t)) { dispatchMain() }
}

// MARK: - the app's side

// One byte out, one back, over a connection kept open while it is in use: its closing is what tells the helper the app is gone.
final class ChargerClient {
    let path: String
    private var fd: Int32 = -1
    init(path: String) { self.path = path }
    // nil: no helper (not installed, not running or not answering).
    func send(_ cut: Bool) -> UInt8? { send(byte: cut ? cmdCut : cmdOn) }
    func send(byte: UInt8) -> UInt8? {
        for _ in 0..<2 {  // a connection to a helper that has since restarted fails once, then a fresh one works
            if fd < 0 { fd = connectHelper() }
            guard fd >= 0 else { return nil }
            var b = byte
            if write(fd, &b, 1) == 1, read(fd, &b, 1) == 1 { return b }
            close(fd); fd = -1  // also on a slow reply: closing makes the helper put power back, and no late reply is misread later
        }
        return nil
    }
    func disconnect() { if fd >= 0 { close(fd); fd = -1 } }
    private func connectHelper() -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        noSigpipeCloexec(s)
        var tv = timeval(tv_sec: 3, tv_usec: 0)  // a hung helper must not hang the app's work queue
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard var a = unixAddress(path) else { close(s); return -1 }
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        if !ok { close(s); return -1 }
        return s
    }
}
