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
    // Under 80 without sailing: off at the limit, on again 5 lower, unchanged in between (the plan, step by step).
    func run(_ levels: [Int], limit: Int, sailing: Bool = false, bottom: Int = 0, fullOnce: Bool = false, temps: [Double?]? = nil, heat: Bool = false) -> [Plan] {
        var resting = false, paused: Int? = nil
        return levels.enumerated().map { i, lv in
            paused = heatStep(on: heat, tempF: temps?[i] ?? nil, level: lv, pausedAt: paused)
            let b = restBottom(limit: limit, sailing: sailing, bottom: bottom)
            resting = nextResting(level: lv, top: limit, bottom: b, resting: resting)
            return plan(level: lv, limit: limit, bottom: b, resting: resting, fullOnce: fullOnce, pausedAt: paused)
        }
    }
    let on = Plan(mac: 80, cut: false), off = Plan(mac: 80, cut: true)
    expect(run([58, 60, 59, 56, 55, 57, 60], limit: 60) == [on, off, off, off, on, on, off], "under 80: off at the limit, on again 5 lower, unchanged in between")
    expect(run([88, 70, 61, 60], limit: 60) == [off, off, off, off], "under 80 set while above 80: off straight away, all the way down")
    expect(run([85, 90, 95], limit: 80) == Array(repeating: on, count: 3) && run([70], limit: 90) == [Plan(mac: 90, cut: false)], "80 and up: the Mac's own limit, never the charger")
    expect(run([60, 56, 55, 52, 50, 51], limit: 60, sailing: true, bottom: 50) == [off, off, off, off, on, on], "sailing replaces the 5-point gap under 80")
    // Sailing range, 80 and up: the Mac's limit moves to the bottom at the top, back to the top at the bottom.
    let top = Plan(mac: 90, cut: false), rest = Plan(mac: 85, cut: false)
    expect(run([86, 90, 88, 86, 85, 87, 90], limit: 90, sailing: true, bottom: 85) == [top, rest, rest, rest, top, top, rest], "sailing: rests down, then charges again")
    expect(run([90, 84, 75, 70, 72], limit: 90, sailing: true, bottom: 70) == [off, off, off, Plan(mac: 90, cut: false), Plan(mac: 90, cut: false)],
           "sailing to a bottom under 80: the charger switch from the top down, then up to the top")
    expect(run([75, 80, 77, 75, 74], limit: 80, sailing: true, bottom: 75) == [on, off, off, on, on], "mockup range 80/75: runs on battery from 80 down to 75")
    expect(run([95, 100], limit: 80, sailing: true, bottom: 75, fullOnce: true) == [Plan(mac: nil, cut: false), Plan(mac: nil, cut: false)], "charge to full once ignores the range")
    expect(nextResting(level: 100, top: 80, bottom: 75, resting: false), "after charging to full once, the range starts with a rest")
    // Heat pause: above 95°F, again at 91°F or cooler; the level it stopped at only moves down.
    expect(heatStep(on: true, tempF: 95, level: 70, pausedAt: nil) == nil && heatStep(on: true, tempF: 95.5, level: 70, pausedAt: nil) == 70, "heat: pauses above 95°F")
    expect(heatStep(on: true, tempF: 93, level: 70, pausedAt: 70) == 70 && heatStep(on: true, tempF: 93, level: 70, pausedAt: nil) == nil, "heat: the 91-95 gap keeps whatever it was")
    expect(heatStep(on: true, tempF: 91, level: 70, pausedAt: 70) == nil, "heat: starts again at 91°F")
    expect(heatStep(on: true, tempF: 99, level: 68, pausedAt: 70) == 68 && heatStep(on: true, tempF: 99, level: 72, pausedAt: 70) == 70, "heat: the pause level only moves down")
    expect(heatStep(on: false, tempF: 99, level: 70, pausedAt: 70) == nil && heatStep(on: true, tempF: nil, level: 70, pausedAt: 70) == nil, "heat: switch off or no reading ends the pause")
    let warm: [Double?] = [90, 99, 99, 93, 93, 90]
    expect(run([84, 86, 86, 86, 86, 86], limit: 95, temps: warm, heat: true) == [Plan(mac: 95, cut: false), Plan(mac: 86, cut: false), Plan(mac: 86, cut: false), Plan(mac: 86, cut: false), Plan(mac: 86, cut: false), Plan(mac: 95, cut: false)],
           "heat at 80 and up: the Mac's limit at the level it paused at, on the charger, back to the limit once cool")
    expect(run([66, 65, 64], limit: 80, temps: [99, 99, 90], heat: true) == [off, off, on], "heat under 80: the charger switch, back on once cool")
    expect(run([56, 52, 50, 52, 55, 56], limit: 80, temps: Array(repeating: 99, count: 6), heat: true) == [off, off, on, on, on, off],
           "heat near 50%: the pause ends at 50 and starts again only above 55 (no switching at every percent)")
    expect(run([90, 92], limit: 80, fullOnce: true, temps: [99, 99], heat: true) == [Plan(mac: 90, cut: false), Plan(mac: 90, cut: false)] && run([70], limit: 80, fullOnce: true, temps: [99], heat: true) == [off],
           "heat during charge to full once")
    expect(run([86, 88], limit: 90, sailing: true, bottom: 85, temps: [99, 99], heat: true) == [Plan(mac: 86, cut: false), Plan(mac: 86, cut: false)], "heat wins over sailing's charging up")
    expect(run([90, 95], limit: 95, sailing: true, bottom: 85, temps: [90, 99], heat: true) == [Plan(mac: 95, cut: false), Plan(mac: 85, cut: false)], "heat with sailing resting: never above the rest")
    expect(run([60, 56, 55], limit: 60, temps: [99, 99, 99], heat: true) == [off, off, off], "heat under 80 keeps the charger off past the 5-point gap")
    expect(clampBottom(75, limit: 80) == 75 && clampBottom(80, limit: 80) == 75 && clampBottom(75, limit: 70) == 65 && clampBottom(10, limit: 80) == 50, "range bottom: at least 5 under the top, pushed down with it")
    expect(bottomRange(50) == 40...45 && bottomRange(55) == 45...50 && bottomRange(80) == 50...75, "range bottom slider always spans a step")
    expect(abs((fahrenheit(centiC: 3019) ?? 0) - 86.342) < 0.01 && fahrenheit(centiC: 3500) == 95 && fahrenheit(centiC: nil) == nil && fahrenheit(centiC: 0) == nil, "battery temperature in °F")
    var h = Snapshot(level: 66, plugged: true, charging: false, limit: 80, mode: .holding, heatOn: true, tempF: 99, paused: true)
    expect(statusText(h) == "Paused, battery warm" && !isCharging(h), "heat pause status")
    h.mode = .fullOnce
    expect(statusText(h) == "Paused, battery warm", "heat pause status during charge to full once")
    h = Snapshot(level: 77, plugged: true, charging: false, limit: 80, mode: .holding, sailing: true, bottom: 75, resting: true)
    expect(statusText(h) == "Resting down to 75%", "sailing: resting")
    h.level = 80
    expect(statusText(h) == "Holding at 80%", "sailing: at the top")
    h.level = 74; h.resting = false; h.charging = true
    expect(statusText(h) == "Charging to 80%" && isCharging(h), "sailing: back at the bottom, charging")
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
    let bt = battery()
    print("battery: level=\(bt.current.map(String.init) ?? "?") temperature=\(bt.tempF.map(degrees) ?? "?")")
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
