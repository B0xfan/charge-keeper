// Entry. No argument (or only arguments macOS adds, not starting with --) = the menu-bar app. The flags below are for the safety watchdog, emergencies and checks.
//   --restore    put the Mac's charge limit back to off / 100 (also works if the app is not running)
//   --probe      read-only: is the limit supported, on or off, which level
//   --selftest   pure logic checks, no hardware
//   --render <folder>   draw the panel and icon to PNG files off-screen (no window, no charge-limit access)
//   --helper <uid>      the charger helper, run as root by launchd (see Charger.swift); --helper-fake <folder> runs it without root on a file
import Foundation
import AppKit

private func s0(charging: Bool, level: Int, plugged: Bool = true) -> Snapshot { Snapshot(level: level, plugged: plugged, charging: charging, limit: 80, mode: .holding) }

// The outline colour of one liveChargingIcon image drawn under the given appearance (white ink on dark, black on light).
@MainActor func inkRed(_ name: NSAppearance.Name) -> CGFloat {
    let img = liveChargingIcon(level: 62, fill: 0.5)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return -1 }
    rep.size = NSSize(width: 30, height: 15)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance { img.draw(in: NSRect(x: 0, y: 0, width: 30, height: 15)) }
    NSGraphicsContext.restoreGraphicsState()
    return rep.colorAt(x: 115, y: 30)?.redComponent ?? -1  // the middle of the battery tip, which is solid ink
}

// In-memory switch for the helper's rules. `broken`: every write fails (an SMC refusal).
final class FakeSwitch: ChargerSwitch {
    var v: UInt8 = powerOn, broken = false
    func read() -> UInt8? { v }
    func write(_ x: UInt8) -> Bool { if broken { return false }; v = x; return true }
}

// The helper's every safety path, on a fake switch and a scratch marker; then the real socket server and client, in-process.
func helperSelftest(_ expect: (Bool, String) -> Void) {
    let dir = NSTemporaryDirectory() + "keeper-selftest-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let marker = dir + "/cut"
    func exists() -> Bool { FileManager.default.fileExists(atPath: marker) }
    let sw = FakeSwitch()
    var g = ChargerGuard(sw, marker: marker, lease: 150, floor: 40)
    expect(g.command(cmdCut, fd: 7, now: 0) == replyCut && sw.v == powerOff && exists(), "cut: power off, marker written first")
    expect(g.command(cmdCut, fd: 7, now: 30) == replyCut && sw.v == powerOff, "renew while off")
    sw.v = powerOn  // the Mac switched it back on by itself (say on a replug)
    expect(g.command(cmdCut, fd: 7, now: 40) == replyCut && sw.v == powerOff, "an undone cut of ours is done again")
    g.closed(8)
    expect(sw.v == powerOff, "another connection closing changes nothing")
    g.closed(7)
    expect(sw.v == powerOn && !exists() && !g.ownCut, "app quit, crashed or killed (its connection closed): power on")
    _ = g.command(cmdCut, fd: 7, now: 100); g.tick(now: 200, level: 70)
    expect(sw.v == powerOff, "inside the check-in time: stays off")
    g.tick(now: 251, level: 70)
    expect(sw.v == powerOn && !exists(), "app stopped checking in (hung): power on")
    _ = g.command(cmdCut, fd: 7, now: 300); g.tick(now: 301, level: 40)
    expect(sw.v == powerOn, "battery floor reached: power on")
    _ = g.command(cmdCut, fd: 7, now: 300); g.tick(now: 301, level: nil)
    expect(sw.v == powerOn, "battery unreadable: power on")
    _ = g.command(cmdCut, fd: 7, now: 300); g.willSleep()
    expect(sw.v == powerOn && !exists(), "sleep: power on")
    _ = g.command(cmdCut, fd: 7, now: 300)
    expect(g.command(cmdOn, fd: 7, now: 301) == replyOn && sw.v == powerOn && !exists(), "the app asks for power: on")
    _ = g.command(cmdCut, fd: 7, now: 300)
    g = ChargerGuard(sw, marker: marker)  // the helper died with power off and starts again (or the Mac restarted)
    expect(sw.v == powerOn && !exists(), "helper start with a cut of ours left: power on")
    sw.v = powerOff  // AlDente's cut, no marker of ours
    g = ChargerGuard(sw, marker: marker)
    expect(sw.v == powerOff, "helper start: another app's cut is left alone")
    expect(g.command(cmdCut, fd: 7, now: 0) == replyBusy && !g.ownCut && !exists(), "cut asked while another app has it off: left alone")
    expect(g.command(cmdOn, fd: 7, now: 0) == replyBusy && sw.v == powerOff, "power asked while another app has it off: left alone")
    g.closed(7); g.willSleep(); g.tick(now: 999, level: 10)
    expect(sw.v == powerOff, "closing, sleep and the floor never touch another app's cut")
    sw.v = powerOn; sw.broken = true
    expect(g.command(cmdCut, fd: 7, now: 0) == replyErr && sw.v == powerOn, "a refused switch: error, nothing changed")
    sw.broken = false; _ = g.command(cmdCut, fd: 7, now: 0); sw.broken = true; g.closed(7)
    expect(sw.v == powerOff && exists(), "a failed power-on keeps the marker")
    sw.broken = false; g.tick(now: 1, level: 70)
    expect(sw.v == powerOn && !exists(), "the next tick tries the power-on again")

    // The socket: a real client connects, cuts, and its closing switches power back on. A stranger's uid is refused.
    let q = DispatchQueue(label: "selftest.helper")
    let fake = FakeSwitch()
    let sg = q.sync { ChargerGuard(fake, marker: dir + "/cut2") }
    let server = HelperServer(sg, queue: q, uid: getuid())
    let sock = dir + "/h.sock"
    guard q.sync(execute: { server.start(path: sock) }) else { expect(false, "helper socket starts"); return }
    let c = ChargerClient(path: sock)
    expect(c.send(true) == replyCut && q.sync { fake.v } == powerOff, "socket: cut")
    c.disconnect()
    usleep(300_000)
    expect(q.sync { fake.v } == powerOn, "socket: the app's connection closing puts power back")
    let other = HelperServer(q.sync { ChargerGuard(FakeSwitch(), marker: dir + "/cut3") }, queue: q, uid: getuid() + 1)
    expect(q.sync(execute: { other.start(path: dir + "/o.sock") }) && ChargerClient(path: dir + "/o.sock").send(true) == nil, "socket: other users are refused")
    expect(ChargerClient(path: dir + "/none.sock").send(true) == nil, "no helper installed: no answer")
    expect(!q.sync(execute: { server.start(path: "/tmp/" + String(repeating: "x", count: 120)) }), "socket: a too-long path is refused, not shortened")
    withExtendedLifetime((server, other)) {}
}

func selftest() -> Int32 {
    var bad = 0
    func expect(_ c: Bool, _ n: String) { if !c { print("FAIL \(n)"); bad += 1 } }
    expect(clampLimit(80) == 80 && clampLimit(83) == 80 && clampLimit(10) == 50 && clampLimit(150) == 100 && clampLimit(-5) == 50, "limit snaps to steps of 5 inside 50...100")
    let hold = Snapshot(level: 80, plugged: true, charging: false, limit: 80, mode: .holding)
    expect(statusText(hold) == "Holding at 80%", "holding at the limit")
    var s = hold; s.level = 60; s.charging = true
    expect(statusText(s) == "Charging to 80%", "charging up to the limit")
    s.plugged = false
    expect(statusText(s) == "On battery", "on battery")
    s = hold; s.mode = .fullOnce; s.level = 80; s.charging = true
    expect(statusText(s) == "Charging to full, once", "charge to full once")
    s.mode = .foreign
    expect(statusText(s) == "Not holding yet", "the Mac's own limit is on")
    s.mode = .steppedAside
    expect(statusText(s) == "Stepped aside" && showsChoice(s.mode) && !isCharging(s), "stepped aside: choice shown, no animation")
    s.mode = .macLimit; s.mac = LimitState(enabled: true, limit: 90)
    expect(statusText(s) == "Mac's limit: 90%" && !showsChoice(s.mode) && !isCharging(s), "the Mac's own limit chosen: level only")
    s.mac = LimitState(enabled: false, limit: 100)
    expect(statusText(s) == "No limit on", "the Mac's own limit chosen but off")
    let on85 = LimitState(enabled: true, limit: 85)
    expect(!changedOutside(cur: on85, held: on85, reassert: false), "slider move (still our old level): not a clash")
    expect(changedOutside(cur: LimitState(enabled: true, limit: 90), held: on85, reassert: false), "a different level set outside: clash")
    expect(changedOutside(cur: LimitState(enabled: false, limit: 85), held: on85, reassert: false), "turned off outside: clash")
    expect(!changedOutside(cur: LimitState(enabled: false, limit: 85), held: on85, reassert: true), "turned off just after wake: set back, not a clash")
    expect(shouldRegisterLoginItem(path: "/Applications/Charge Keeper.app", asked: false), "login item: installed copy, first time")
    expect(!shouldRegisterLoginItem(path: "/Applications/Charge Keeper.app", asked: true), "login item: asked only once")
    expect(!shouldRegisterLoginItem(path: "/Users/x/charge-keeper/build/Charge Keeper.app", asked: false), "login item: never for a build-folder copy")
    expect(isCharging(s0(charging: true, level: 62)) && !isCharging(s0(charging: true, level: 80)) && !isCharging(s0(charging: false, level: 62)) && !isCharging(s0(charging: true, level: 62, plugged: false)), "animation only while really charging")
    expect(sweepAmount(0) == 0 && sweepAmount(1.6) == 1 && sweepAmount(1.9) == 1 && sweepAmount(0.8) > sweepAmount(0.4) && abs(sweepAmount(0.8) - 0.5) < 1e-9, "sweep grows, rests, restarts")
    for off in [0, 0.1, 0.17, 0.3] {  // the timer's ticks fall anywhere in the 2 s round
        let frames = Set((0..<Int(2 * sweepFPS)).map { sweepAmount(off + Double($0) / sweepFPS) })
        expect(frames.count >= 5, "sweep at its slower rate shows at least 5 pictures per round (start offset \(off))")
    }
    expect(MainActor.assumeIsolated { inkRed(.darkAqua) > 0.8 && inkRed(.aqua) < 0.2 }, "menu-bar charging picture follows the drawing appearance (one image, drawn twice)")
    // Under 80: off at the limit, on again 5 lower, unchanged in between; 80 and up and a closed lid never switch.
    expect(cutWanted(level: 60, limit: 60, cutNow: false, lidClosed: false) && cutWanted(level: 85, limit: 60, cutNow: false, lidClosed: false), "cut point: at or above the limit")
    expect(cutWanted(level: 56, limit: 60, cutNow: true, lidClosed: false) && !cutWanted(level: 59, limit: 60, cutNow: false, lidClosed: false), "between the points: unchanged")
    expect(!cutWanted(level: 55, limit: 60, cutNow: true, lidClosed: false) && !cutWanted(level: 45, limit: 50, cutNow: true, lidClosed: false), "restore point: 5 under the limit")
    expect(!cutWanted(level: 95, limit: 80, cutNow: true, lidClosed: false) && !cutWanted(level: 70, limit: 60, cutNow: true, lidClosed: true), "never at 80 and up, never with the lid closed")
    var t = Snapshot(level: 70, plugged: false, charging: false, limit: 60, mode: .holding, cut: true)
    expect(statusText(t) == "Coming down to 60%" && !isCharging(t), "cut above the limit")
    t.level = 58
    expect(statusText(t) == "Holding at 60%", "cut inside the range")
    t = Snapshot(level: 70, plugged: true, charging: true, limit: 60, mode: .holding, cutNote: .noHelper)
    expect(statusText(t) == "Charging to 80%" && isCharging(t), "no helper: the Mac's 80 holds and the text says so")
    helperSelftest(expect)
    print(bad == 0 ? "selftest ok" : "selftest FAILED")
    return bad == 0 ? 0 : 1
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "--watchdog": runWatchdog(args)
case "--helper", "--helper-fake": runHelper(args)
case "--selftest": exit(selftest())
case "--render": exit(MainActor.assumeIsolated { renderAll(to: args.count > 2 ? args[2] : "keeper-render") } ? 0 : 1)
case "--probe":
    guard let m = MCL() else { print("PowerUI client could not be created"); exit(1) }
    let st = m.state()
    print("mcl: supported=\(m.supported) enabled=\(st.map { "\($0.enabled)" } ?? "?") limit=\(st.map { "\($0.limit)" } ?? "?")")
case "--restore":
    guard let m = MCL() else { print("PowerUI client could not be created"); exit(2) }
    let ok = restore(m, LimitState(enabled: false, limit: 100))
    if ok { try? FileManager.default.removeItem(at: markerURL) }
    print("restore: \(ok) state=\(String(describing: m.state()))")
    exit(ok ? 0 : 1)
default:
    // A second copy would show a second icon and switch off the first copy's live limit at start-up, so it just leaves.
    // An unknown --flag (say --help typed in a terminal) must not start the app either; other arguments (-psn_*,
    // -ApplePersistenceIgnoreState, ... added by macOS, open or a debugger) are ignored. The lock is the check: a copy started
    // from a terminal is not always listed as a running app yet. O_CLOEXEC: the watchdog must not inherit it and hold it after the app dies.
    func leave(_ why: String, _ code: Int32) -> Never { FileHandle.standardError.write(Data("Charge Keeper: \(why)\n".utf8)); exit(code) }
    let known: Set = ["-watchdog", "-selftest", "-render", "-probe", "-restore", "-helper", "-helper-fake"]  // single-dash typos of our own flags
    if let bad = args.dropFirst().first(where: { $0.hasPrefix("--") || known.contains($0) }) {
        leave("unknown option \(bad). Usage: ChargeKeeper (no arguments) | --selftest | --probe | --restore | --render <folder> | --helper <uid>", 2)
    }
    let lockDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Charge Keeper")
    try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
    // Never close lockFd: the lock is held for as long as this descriptor stays open, i.e. until the app exits.
    let lockFd = open(lockDir.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    let locked = lockFd >= 0 && flock(lockFd, LOCK_EX | LOCK_NB) == 0
    if !locked && lockFd >= 0 && errno == EWOULDBLOCK { leave("already running, this copy exits", 0) }
    if !locked, let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
        // No usable lock (open or flock failed for another reason): fall back to the running-app list. If that check is wrong we still start, so there is always an app at login.
        leave("already running, this copy exits", 0)
    }
    runApp()
}
