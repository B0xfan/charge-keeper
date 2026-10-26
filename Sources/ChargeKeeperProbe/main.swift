// Charge Keeper, phase 1 proof: can this Mac be told to stop charging and always get it back?
// Original code. Facts used: the AppleSMC user client takes an 80-byte request through IOConnectCallStructMethod
// (selector 2); charge-inhibit keys are CH0B/CH0C (older firmware) and CHTE (newer firmware).
//
//   probe          read-only: which charging keys exist and their values, plus battery state (works without root)
//   test [--sleep] needs root: stop charging, check it, restore, check it; kill test; optional sleep/wake test
//   restore        needs root: put the charge-inhibit keys back to "charging on"
//   selftest       pure logic checks (no hardware)
import Foundation
import IOKit

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - byte helpers

func fcc(_ s: String) -> UInt32 { s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
func fccString(_ v: UInt32) -> String {
    String(decoding: [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)], as: UTF8.self)
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> [UInt8]? {
    guard s.count % 2 == 0, !s.isEmpty else { return nil }
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        guard let v = UInt8(s[i..<j], radix: 16) else { return nil }
        out.append(v)
        i = j
    }
    return out
}
func get32(_ b: [UInt8], _ o: Int) -> UInt32 {
    let a = UInt32(b[o]), c = UInt32(b[o + 1]) << 8, d = UInt32(b[o + 2]) << 16, e = UInt32(b[o + 3]) << 24
    return a | c | d | e
}
func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    for i in 0..<4 { b[o + i] = UInt8((v >> UInt32(8 * i)) & 255) }
}

// MARK: - SMC access (request layout: key@0, dataSize@28, dataType@32, result@40, command@42, index@44, bytes@48)

struct KeyInfo { let size: Int; let type: String }

final class SMC {
    private var conn: io_connect_t = 0
    init?() {
        let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }
    deinit { IOServiceClose(conn) }

    // Returns the reply only when the call went through and the SMC reported result 0.
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let rc = input.withUnsafeBytes { ib in
            out.withUnsafeMutableBytes { ob in
                IOConnectCallStructMethod(conn, 2, ib.baseAddress, 80, ob.baseAddress, &outSize)
            }
        }
        return rc == KERN_SUCCESS && out[40] == 0 ? out : nil
    }
    private func request(_ key: String, cmd: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 80)
        put32(&b, 0, fcc(key))
        b[42] = cmd
        return b
    }
    func info(_ key: String) -> KeyInfo? {
        guard let o = call(request(key, cmd: 9)) else { return nil }
        let size = Int(get32(o, 28))
        return size > 0 && size <= 32 ? KeyInfo(size: size, type: fccString(get32(o, 32))) : nil
    }
    func read(_ key: String) -> [UInt8]? {
        guard let i = info(key) else { return nil }
        var b = request(key, cmd: 5)
        put32(&b, 28, UInt32(i.size))
        guard let o = call(b) else { return nil }
        return Array(o[48..<(48 + i.size)])
    }
    // Only ever called with a key that was read first (see Plan below).
    func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let i = info(key), i.size == bytes.count else { return false }
        var b = request(key, cmd: 6)
        put32(&b, 28, UInt32(i.size))
        for (n, v) in bytes.enumerated() { b[48 + n] = v }
        return call(b) != nil
    }
    func keyCount() -> Int {
        guard let v = read("#KEY"), v.count == 4 else { return 0 }
        return Int(v.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }
    func key(at index: Int) -> String? {
        var b = request("", cmd: 8)
        put32(&b, 44, UInt32(index))
        guard let o = call(b) else { return nil }
        return fccString(get32(o, 0))
    }
}

// MARK: - which keys to use

// One key to switch, the value that stops charging, the exact value read before (restored afterwards).
struct Step { let key: String; let inhibit: [UInt8]; let original: [UInt8] }

// Pure decision: only keys that exist with the expected size, and only when they currently read as "charging on" (all zero).
func chooseSteps(info: [String: KeyInfo], values: [String: [UInt8]]) -> [Step]? {
    func ok(_ k: String, _ size: Int) -> Bool {
        info[k]?.size == size && values[k]?.count == size && values[k]!.allSatisfy { $0 == 0 }
    }
    if ok("CHTE", 4) { return [Step(key: "CHTE", inhibit: [1, 0, 0, 0], original: values["CHTE"]!)] }
    if ok("CH0B", 1) && ok("CH0C", 1) {
        return [Step(key: "CH0B", inhibit: [2], original: values["CH0B"]!), Step(key: "CH0C", inhibit: [2], original: values["CH0C"]!)]
    }
    return nil
}

let candidateKeys = ["CH0B", "CH0C", "CH0I", "CHTE", "CHIE", "BCLM"]

// MARK: - battery state

struct Battery {
    var charging: Bool?, external: Bool?, current: Int?, max: Int?, amps: Int?
    var text: String {
        func s<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "?" }
        return "charging=\(s(charging)) plugged_in=\(s(external)) level=\(s(current))/\(s(max)) amperage_mA=\(s(amps))"
    }
}
func battery() -> Battery {
    let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return Battery() }
    defer { IOObjectRelease(svc) }
    func p(_ k: String) -> NSNumber? { IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber }
    return Battery(charging: p("IsCharging")?.boolValue, external: p("ExternalConnected")?.boolValue,
                   current: p("CurrentCapacity")?.intValue, max: p("MaxCapacity")?.intValue, amps: p("Amperage").map { Int($0.int64Value) })
}

func waitFor(_ seconds: Int, _ cond: () -> Bool) -> Bool {
    for _ in 0..<(seconds / 2 + 1) {
        if cond() { return true }
        sleep(2)
    }
    return cond()
}

// MARK: - the hold: stop charging with a watchdog that puts it back no matter how this process ends

func selfPath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}

// Starts a process in its own session, so a Ctrl-C or a kill aimed at this tool does not reach it.
func spawnDetached(_ args: [String]) -> pid_t? {
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    var defaults = sigset_t()
    sigfillset(&defaults)  // the parent ignores SIGINT/SIGTERM; the watchdog must not inherit that
    posix_spawnattr_setsigdefault(&attr, &defaults)
    posix_spawnattr_setflags(&attr, Int16(0x0400 | 0x04))  // POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF
    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
    var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    cargs.append(nil)
    var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)
    defer { cargs.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, args[0], &fa, &attr, cargs, envp)
    return rc == 0 ? pid : nil
}

// Writes every original back (only where it differs), verifies by reading, retries.
func restoreAll(_ smc: SMC, _ steps: [Step], tries: Int = 5) -> Bool {
    for _ in 0..<tries {
        var all = true
        for s in steps where smc.read(s.key) != s.original {
            _ = smc.write(s.key, s.original)
            if smc.read(s.key) != s.original { all = false }
        }
        if all { return true }
        sleep(1)
    }
    return false
}

final class Hold {
    let smc: SMC, steps: [Step]
    private var watchdog: pid_t = 0
    private let lock = NSLock()
    private var active = false
    init(_ smc: SMC, _ steps: [Step]) { self.smc = smc; self.steps = steps }

    func engage(deadline: Int) -> Bool {
        let wdArgs = [selfPath(), "watchdog", String(getpid()), String(deadline)] + steps.map { "\($0.key)=\(hex($0.original))" }
        guard let pid = spawnDetached(wdArgs) else { return false }
        watchdog = pid
        usleep(700_000)
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == 0 else { return false }  // already exited: no watchdog, no inhibit
        // The lock is held for the whole write loop, so a signal's release() waits and then restores everything.
        lock.lock(); defer { lock.unlock() }
        active = true
        for s in steps {
            guard smc.write(s.key, s.inhibit), smc.read(s.key) == s.inhibit else { releaseLocked(); return false }
        }
        return true
    }
    // Safe to call from anywhere, any number of times.
    func release() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return releaseLocked()
    }
    @discardableResult private func releaseLocked() -> Bool {
        guard active else { return true }
        let ok = restoreAll(smc, steps)
        if ok { active = false; if watchdog > 0 { kill(watchdog, SIGTERM); watchdog = 0 } }  // watchdog only exits; the parent already restored
        return ok
    }
}

var currentHold: Hold? = nil
var signalSources: [DispatchSourceSignal] = []

// Every ending we can catch (normal exit, Ctrl-C, terminate, hangup) restores charging first.
func installExitSafety() {
    atexit { _ = currentHold?.release() }
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
        src.setEventHandler {
            let ok = currentHold?.release() ?? true
            print(ok ? "signal \(sig): charging restored" : "signal \(sig): RESTORE FAILED, run restore")
            exit(130)
        }
        src.resume()
        signalSources.append(src)
    }
}

// MARK: - commands

func probe() -> (smc: SMC?, info: [String: KeyInfo], values: [String: [UInt8]]) {
    print("user id: \(geteuid()) (root is only needed to change keys)")
    guard let smc = SMC() else { print("AppleSMC: could not open"); return (nil, [:], [:]) }
    var names = candidateKeys
    let n = smc.keyCount()
    print("AppleSMC: open, \(n) keys")
    for i in 0..<n {
        if let k = smc.key(at: i), (k.hasPrefix("CH") || k.hasPrefix("BCL")), !names.contains(k) { names.append(k) }
    }
    var info: [String: KeyInfo] = [:], values: [String: [UInt8]] = [:]
    for k in names {
        if let i = smc.info(k) {
            info[k] = i
            let v = smc.read(k)
            if let v = v { values[k] = v }
            print("  \(k): exists, size \(i.size), type \(i.type), value \(v.map(hex) ?? "unreadable")")
        } else if candidateKeys.contains(k) {
            print("  \(k): not present")
        }
    }
    print("battery: \(battery().text)")
    return (smc, info, values)
}

func sleepWakeCycle() -> Int {
    let wake = Date().addingTimeInterval(60)
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM/dd/yy HH:mm:ss"
    let stamp = f.string(from: wake)
    func pm(_ a: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = a; try? p.run(); p.waitUntilExit() }
    pm(["schedule", "wake", stamp])
    let wall0 = Date(), up0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    pm(["sleepnow"])
    var slept = 0
    for _ in 0..<120 {
        sleep(1)
        let wall = Date().timeIntervalSince(wall0)
        let up = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - up0) / 1e9
        if wall - up > 15 { slept = Int(wall - up); break }
    }
    pm(["schedule", "cancel", "wake", stamp])
    return slept
}

func runTest(sleepTest: Bool) -> Int32 {
    guard geteuid() == 0 else { print("test needs root"); return 2 }
    let (maybeSmc, info, values) = probe()
    guard let smc = maybeSmc else { return 1 }
    guard let steps = chooseSteps(info: info, values: values) else {
        print("RESULT: no charge-inhibit key clearly identified (or it is not currently all zero). Nothing was written.")
        return 1
    }
    let b0 = battery()
    guard b0.external == true, b0.charging == true else {
        print("RESULT: Mac is not plugged in and charging right now (\(b0.text)), so a stop cannot be shown. Nothing was written.")
        return 1
    }
    print("using keys: \(steps.map { $0.key }.joined(separator: ", ")); original values: \(steps.map { hex($0.original) }.joined(separator: ", "))")
    installExitSafety()
    let hold = Hold(smc, steps)
    currentHold = hold
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
        if !ok { failures += 1 }
    }

    // A: stop, observe, restore, observe
    guard hold.engage(deadline: 900) else { print("FAIL could not engage (watchdog or write failed); charging restored: \(restoreAll(smc, steps))"); return 1 }
    for s in steps { print("wrote \(s.key)=\(hex(s.inhibit)), read back \(smc.read(s.key).map(hex) ?? "?")") }
    let stopped = waitFor(60) { battery().charging == false }
    check("A1 charging stopped after writing the key", stopped, battery().text)
    var persisted = true
    if sleepTest {
        let n = sleepWakeCycle()
        print("slept about \(n) s")
        check("A2 the Mac really slept", n > 15)
        let right = steps.map { smc.read($0.key) == $0.inhibit }.allSatisfy { $0 }
        sleep(5)
        let later = steps.map { smc.read($0.key) == $0.inhibit }.allSatisfy { $0 }
        persisted = right && later
        print("INFO key kept its stop value across sleep/wake: immediately \(right), 5 s later \(later); battery \(battery().text)")
    }
    check("A3 restore verified by reading the key", hold.release())
    let back = waitFor(60) { battery().charging == true }
    check("A4 charging resumed after restore", back, battery().text)
    currentHold = nil

    // B: the tool is killed hard while charging is stopped
    let child = Process()
    child.executableURL = URL(fileURLWithPath: selfPath())
    child.arguments = ["hold", "120"]
    let pipe = Pipe()
    child.standardOutput = pipe
    do { try child.run() } catch { check("B0 start hold process", false); return 1 }
    let line = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
    let held = line.contains("held") && steps.map({ smc.read($0.key) == $0.inhibit }).allSatisfy { $0 }
    check("B1 second process is holding charging off", held)
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    let restored = waitFor(10) { steps.map { smc.read($0.key) == $0.original }.allSatisfy { $0 } }
    check("B2 after kill -9 the watchdog put the key back", restored)
    if !restored { print("emergency restore: \(restoreAll(smc, steps))") }
    check("B3 charging resumed after kill -9", waitFor(60) { battery().charging == true }, battery().text)

    let finalOK = steps.allSatisfy { smc.read($0.key) == $0.original }
    print("FINAL: keys at original value: \(finalOK); battery \(battery().text)")
    print("RESULT: \(failures == 0 && finalOK ? "PROVEN" : "NOT PROVEN") (key survives sleep: \(sleepTest ? "\(persisted)" : "not tested"))")
    return failures == 0 && finalOK ? 0 : 1
}

func selftest() -> Int32 {
    var bad = 0
    func expect(_ c: Bool, _ n: String) { if !c { print("FAIL \(n)"); bad += 1 } }
    expect(fccString(fcc("CHTE")) == "CHTE", "fourcc roundtrip")
    expect(unhex("0a01ff") == [10, 1, 255] && unhex("0g") == nil && unhex("abc") == nil, "hex")
    var b = [UInt8](repeating: 0, count: 8); put32(&b, 2, 0x01020304)
    expect(get32(b, 2) == 0x01020304 && b[2] == 4, "u32 little endian")
    let i4 = KeyInfo(size: 4, type: "ui32"), i1 = KeyInfo(size: 1, type: "ui8")
    expect(chooseSteps(info: ["CHTE": i4], values: ["CHTE": [0, 0, 0, 0]])?.first?.inhibit == [1, 0, 0, 0], "CHTE chosen")
    expect(chooseSteps(info: ["CH0B": i1, "CH0C": i1], values: ["CH0B": [0], "CH0C": [0]])?.count == 2, "CH0B+CH0C chosen")
    expect(chooseSteps(info: ["CH0B": i1], values: ["CH0B": [0]]) == nil, "CH0B alone refused")
    expect(chooseSteps(info: ["CHTE": i4], values: ["CHTE": [1, 0, 0, 0]]) == nil, "already inhibited refused")
    expect(chooseSteps(info: ["CHTE": i1], values: ["CHTE": [0]]) == nil, "wrong size refused")
    expect(chooseSteps(info: [:], values: [:]) == nil, "nothing present")
    print(bad == 0 ? "selftest ok" : "selftest FAILED")
    return bad == 0 ? 0 : 1
}

// MARK: - entry

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "probe" {
case "probe":
    _ = probe()
case "test":
    exit(runTest(sleepTest: args.contains("--sleep")))
case "restore":
    guard geteuid() == 0, let smc = SMC() else { print("restore needs root"); exit(2) }
    // The only values ever written are the documented "charging on" zeros, and only to a key that exists with its expected size.
    var ok = true
    for (k, size) in [("CHTE", 4), ("CH0B", 1), ("CH0C", 1)] where smc.info(k)?.size == size {
        let zero = [UInt8](repeating: 0, count: size)
        if smc.read(k) != zero { ok = smc.write(k, zero) && smc.read(k) == zero && ok }
        print("\(k): \(smc.read(k).map(hex) ?? "?")")
    }
    exit(ok ? 0 : 1)
case "hold":  // internal: used by the kill test
    guard geteuid() == 0, let smc = SMC() else { exit(2) }
    var info: [String: KeyInfo] = [:], values: [String: [UInt8]] = [:]
    for k in candidateKeys { if let i = smc.info(k) { info[k] = i; values[k] = smc.read(k) } }
    guard let steps = chooseSteps(info: info, values: values) else { print("refused"); exit(1) }
    installExitSafety()
    let hold = Hold(smc, steps)
    currentHold = hold
    guard hold.engage(deadline: 150) else { print("failed"); exit(1) }
    print("held")
    sleep(UInt32(args.count > 2 ? Int(args[2]) ?? 30 : 30))
    exit(hold.release() ? 0 : 1)
case "watchdog":  // internal: args = parent pid, deadline seconds, KEY=originalhex ...
    guard args.count > 4, let deadline = Int(args[3]), let smc = SMC() else { exit(2) }
    guard let parent = pid_t(args[2]) else { exit(2) }  // the pid given at spawn, so a parent that died early is noticed
    var steps: [Step] = []
    for a in args[4...] {
        let p = a.split(separator: "=").map(String.init)
        guard p.count == 2, let o = unhex(p[1]) else { exit(2) }
        steps.append(Step(key: p[0], inhibit: [], original: o))
    }
    let end = Date().addingTimeInterval(TimeInterval(deadline))
    // getppid changes when the parent dies, even if the parent is a zombie
    while getppid() == parent && Date() < end { usleep(300_000) }
    exit(restoreAll(smc, steps, tries: 20) ? 0 : 1)
case "selftest":
    exit(selftest())
default:
    print("usage: probe | test [--sleep] | restore | selftest")
    exit(2)
}
