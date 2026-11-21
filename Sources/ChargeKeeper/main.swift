// Entry. No argument (or only arguments macOS adds, not starting with --) = the menu-bar app. The flags below are for the safety watchdog, emergencies and checks.
//   --restore    put the Mac's charge limit back to off / 100 (also works if the app is not running)
//   --probe      read-only: is the limit supported, on or off, which level
//   --selftest   logic checks plus one end-to-end run on a fake helper (--test-client <socket> is its stand-in app); no hardware
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
    // Mockup v3 helper parts: the deep cut's lower floor, low power and the MagSafe light (given back when its line closes).
    let dsw = FakeSwitch()
    let dg = ChargerGuard(dsw, marker: dir + "/cut4")
    _ = dg.command(cmdDeep, fd: 7, now: 0); dg.tick(now: 1, level: 30)
    expect(dsw.v == powerOff, "deep cut: stays off under the normal floor of 40")
    dg.tick(now: 2, level: deepFloor)
    expect(dsw.v == powerOn, "deep cut: power on at its own floor")
    _ = dg.command(cmdDeep, fd: 7, now: 3); _ = dg.command(cmdCut, fd: 7, now: 4); dg.tick(now: 5, level: 30)
    expect(dsw.v == powerOn, "a normal cut after a deep one has the normal floor again")
    let led = FakeSwitch(); var lp: Bool? = nil
    let ex = Extras(led: led, lowPower: { lp = $0; return true })
    expect(ex.command(cmdLowOn, fd: 7) == replyDone && lp == true && ex.command(cmdLowOff, fd: 7) == replyDone && lp == false, "low power on and off")
    expect(ex.command(cmdLedDark, fd: 7) == replyDone && led.v == ledOff, "MagSafe light dark")
    ex.closed(8)
    expect(led.v == ledOff, "another line closing leaves the light")
    ex.closed(7)
    expect(led.v == ledSystem, "the app's line closing gives the light back to macOS")
    expect(ex.command(cmdCut, fd: 7) == nil && Extras(led: nil, lowPower: { _ in false }).command(cmdLedDark, fd: 7) == replyErr, "extras: the charger's commands pass through; no light key is an error")
    let lsrv = HelperServer(q.sync { ChargerGuard(FakeSwitch(), marker: dir + "/cut5") }, queue: q, uid: getuid(), extras: ex)
    expect(q.sync(execute: { lsrv.start(path: dir + "/l.sock") }), "socket with extras starts")
    let lc = ChargerClient(path: dir + "/l.sock")
    expect(lc.send(byte: cmdLedDark) == replyDone && q.sync { led.v } == ledOff, "socket: light dark")
    lc.disconnect(); usleep(300_000)
    expect(q.sync { led.v } == ledSystem, "socket: the app quitting gives the light back")
    withExtendedLifetime(lsrv) {}
    withExtendedLifetime((server, other)) {}

    // Intel (mockup v4): the helper's BCLM limit, owned by the app's connection. Not run on Intel hardware (none here).
    let bc = FakeSwitch(); bc.v = noLimit
    let lmark = dir + "/limit"
    func lexists() -> Bool { FileManager.default.fileExists(atPath: lmark) }
    var lg = LimitGuard(bc, marker: lmark, lease: 150)
    expect(lg.command(cmdCut, fd: 7, now: 0) == nil && lg.command(cmdLedDark, fd: 7, now: 0) == nil, "intel: the other commands pass through the limit guard")
    expect(lg.command(limitCommand(60), fd: 7, now: 0) == replyDone && bc.v == 60 && lexists(), "intel: limit 60 set, marker written")
    expect(lg.command(limitCommand(75), fd: 7, now: 30) == replyDone && bc.v == 75, "intel: a new limit")
    lg.closed(8); expect(bc.v == 75, "intel: another connection closing changes nothing")
    lg.closed(7); expect(bc.v == noLimit && !lexists(), "intel: the app quit, crashed or was killed: no limit")
    _ = lg.command(limitCommand(70), fd: 7, now: 100); lg.tick(now: 200); expect(bc.v == 70, "intel: inside the check-in time the limit stays")
    lg.tick(now: 251); expect(bc.v == noLimit && !lexists(), "intel: the app stopped checking in: no limit")
    _ = lg.command(limitCommand(70), fd: 7, now: 300)
    expect(lg.command(limitCommand(100), fd: 7, now: 301) == replyDone && bc.v == noLimit && !lexists(), "intel: 100 gives the limit back")
    _ = lg.command(limitCommand(70), fd: 7, now: 300)
    lg = LimitGuard(bc, marker: lmark)  // the helper died with our limit on, or the Mac restarted
    expect(bc.v == noLimit && !lexists(), "intel: helper start with a limit of ours left: no limit")
    bc.v = 80  // another app's limit, no marker of ours
    lg = LimitGuard(bc, marker: lmark)
    expect(bc.v == 80 && lg.command(limitCommand(60), fd: 7, now: 0) == replyBusy && bc.v == 80 && !lexists(), "intel: another app's limit is left alone")
    lg.closed(7); lg.tick(now: 999); expect(bc.v == 80, "intel: closing and ticks never touch another app's limit")
    bc.v = noLimit; bc.broken = true
    expect(lg.command(limitCommand(60), fd: 7, now: 0) == replyErr && bc.v == noLimit, "intel: a refused write is an error")
    bc.broken = false; _ = lg.command(limitCommand(60), fd: 7, now: 0); bc.broken = true; lg.closed(7)
    expect(bc.v == 60 && lexists(), "intel: a failed give-back keeps the marker")
    bc.broken = false; lg.tick(now: 1); expect(bc.v == noLimit && !lexists(), "intel: the next tick gives it back")
    expect(LimitGuard(nil, marker: dir + "/limit2").command(limitCommand(60), fd: 7, now: 0) == replyErr, "apple chip: no BCLM key, a limit byte is an error")
    let ibc = FakeSwitch(); ibc.v = noLimit
    let isrv = HelperServer(q.sync { ChargerGuard(FakeSwitch(), marker: dir + "/cut6") }, queue: q, uid: getuid(), limits: q.sync { LimitGuard(ibc, marker: dir + "/limit3") })
    expect(q.sync(execute: { isrv.start(path: dir + "/i.sock") }), "intel socket starts")
    let ic = ChargerClient(path: dir + "/i.sock")
    expect(ic.send(byte: limitCommand(65)) == replyDone && q.sync { ibc.v } == 65 && ic.send(byte: cmdCut) == replyCut, "intel socket: limit and cut on one helper")
    ic.disconnect(); usleep(300_000)
    expect(q.sync { ibc.v } == noLimit, "intel socket: the app's connection closing gives the limit back")
    withExtendedLifetime(isrv) {}
}

// End to end: the real helper (--helper-fake, its own process) and a stand-in app (its own process) that cuts charger power
// and is then killed hard. The helper must put power back once the app's connection drops.
func endToEndSelftest(_ expect: (Bool, String) -> Void) {
    let dir = NSTemporaryDirectory() + "keeper-e2e-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func waitFor(_ ok: () -> Bool) -> Bool { for _ in 0..<50 { if ok() { return true }; usleep(100_000) }; return false }
    let devnull = open("/dev/null", O_WRONLY)
    defer { close(devnull) }
    guard let helper = spawnDetached([selfPath(), "--helper-fake", dir], stdoutFd: devnull) else { return expect(false, "e2e: helper starts") }
    defer { kill(helper, SIGKILL); waitpid(helper, nil, 0) }
    let sw = FileSwitch(dir + "/switch")
    guard waitFor({ FileManager.default.fileExists(atPath: dir + "/helper.sock") }) else { return expect(false, "e2e: helper socket appears") }
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return expect(false, "e2e: pipe") }
    let app = spawnDetached([selfPath(), "--test-client", dir + "/helper.sock"], stdoutFd: fds[1])
    close(fds[1])
    var reply: UInt8 = 0
    var pfd = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
    // the stand-in writes the helper's answer; EOF if it died first. Timed, as the helper install runs this self-test.
    let got = app != nil && poll(&pfd, 1, 5000) == 1 && read(fds[0], &reply, 1) == 1
    close(fds[0])
    guard let app else { return expect(false, "e2e: stand-in app starts") }
    expect(got && reply == replyCut && sw.read() == powerOff, "e2e: the app process cut charger power")
    kill(app, SIGKILL); waitpid(app, nil, 0)
    expect(waitFor { sw.read() == powerOn }, "e2e: app killed hard: the helper puts charger power back")
}

func featureSelftest(_ expect: (Bool, String) -> Void) {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    func d(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }  // Nov 16 2026 is a Monday
    let trip = Schedule(name: "Trip", limit: 100, from: d(17, 7), until: d(18, 18))
    expect(occurrenceEnd(trip, now: d(17, 6), cal: cal) == nil && occurrenceEnd(trip, now: d(17, 7), cal: cal) == d(18, 18) && occurrenceEnd(trip, now: d(18, 18), cal: cal) == nil, "once: runs from its start up to its end")
    expect(expired(trip, now: d(18, 18)) && !expired(trip, now: d(18, 17)), "once: ends itself")
    let wk = Schedule(name: "Weekdays", limit: 90, days: weekdays, from: d(16, 6), until: d(16, 8))
    expect(occurrenceEnd(wk, now: d(16, 7), cal: cal) == d(16, 8) && occurrenceEnd(wk, now: d(16, 8), cal: cal) == nil && occurrenceEnd(wk, now: d(21, 7), cal: cal) == nil, "weekdays 6 to 8: Monday yes, Saturday no")
    let night = Schedule(name: "Night", limit: 60, days: [2], from: d(16, 22), until: d(16, 6))
    expect(occurrenceEnd(night, now: d(16, 23), cal: cal) == d(17, 6) && occurrenceEnd(night, now: d(17, 5), cal: cal) == d(17, 6) && occurrenceEnd(night, now: d(17, 23), cal: cal) == nil, "overnight: Monday 22:00 to Tuesday 6:00")
    var off = wk; off.on = false
    expect(occurrenceEnd(off, now: d(16, 7), cal: cal) == nil, "a switched-off schedule never runs")
    let both = [wk, trip]
    expect(activeSchedule(both, now: d(17, 7, 30), skipped: [:], cal: cal)?.0.name == "Trip", "two running: the higher limit wins")
    expect(activeSchedule(both, now: d(17, 7, 30), skipped: [trip.id: d(18, 18)], cal: cal)?.0.name == "Weekdays", "skip this time leaves that occurrence out")
    expect(activeSchedule([wk], now: d(17, 7), skipped: [wk.id: d(16, 8)], cal: cal) != nil, "a skip covers only its own occurrence")
    expect(toChip(powerOff, off: 0x01) == 0x01 && toChip(powerOn, off: 0x01) == 0x00 && fromChip(0x01, off: 0x01) == powerOff && fromChip(0x00, off: 0x01) == powerOn && fromChip(0x20, off: 0x01) == powerOff, "older Apple chips (CH0I/CH0J): off is 1")
    expect(toChip(powerOff, off: 0x08) == 0x08 && fromChip(0x08, off: 0x08) == powerOff && toChip(ledOff, off: nil) == ledOff && fromChip(0x01, off: nil) == 0x01, "M2 (CHIE) and the MagSafe light unchanged")
    expect(nextCalibration(months: 0, last: d(1, 9), since: nil, cal: cal) == nil && nextCalibration(months: 1, last: nil, since: nil, cal: cal) == nil, "no calibration schedule: never due")
    expect(nextCalibration(months: 1, last: d(1, 9), since: nil, cal: cal) == cal.date(byAdding: .month, value: 1, to: d(1, 9)), "monthly: a month after the last run")
    expect(nextCalibration(months: 2, last: d(1, 9), since: d(16, 9), cal: cal) == cal.date(byAdding: .month, value: 2, to: d(16, 9)), "set or cancelled later: counted from then")
    expect(nextCalib(1, level: 99) == 1 && nextCalib(1, level: 100) == 2 && nextCalib(2, level: 16) == 2 && nextCalib(2, level: calibFloor) == 3
           && nextCalib(3, level: 100) == nil && nextCalib(2, level: nil) == 2, "calibration: full, down to 15, full, done")
    expect(ledDark(.offWhileHeld, plugged: true, charging: false) && !ledDark(.offWhileHeld, plugged: true, charging: true) && ledDark(.off, plugged: true, charging: true)
           && !ledDark(.off, plugged: false, charging: false) && !ledDark(.normal, plugged: true, charging: false), "MagSafe light rules")
    expect(linkAction(URL(string: "chargekeeper://limit/80")!) == .limit(80) && linkAction(URL(string: "chargekeeper://full")!) == .full
           && linkAction(URL(string: "ChargeKeeper://rundown")!) == .runDown && linkAction(URL(string: "chargekeeper://limit/30")!) == nil
           && linkAction(URL(string: "chargekeeper://limit/abc")!) == nil && linkAction(URL(string: "https://limit/80")!) == nil, "links")
    expect(linkAction(URL(string: "chargekeeper://heat/on")!) == .heat(true) && linkAction(URL(string: "chargekeeper://sailing/OFF")!) == .sailing(false)
           && linkAction(URL(string: "chargekeeper://lowpower/on")!) == .lowPower(true) && linkAction(URL(string: "chargekeeper://calibration/off")!) == .calibration(false)
           && linkAction(URL(string: "chargekeeper://heat")!) == nil && linkAction(URL(string: "chargekeeper://heat/maybe")!) == nil, "links for every switch")
    expect(linkExamples.allSatisfy { linkAction(URL(string: $0)!) != nil }, "every link shown in Settings works")
    // Intel (mockup v4): the limit byte, the floor of 0 (BCLM holds any limit, no charger switch), the helper's replies.
    expect(limitCommand(60) == 0x80 + 60 && limitValue(limitCommand(60)) == 60 && limitValue(limitCommand(100)) == 100 && limitCommand(62) == 0x80 + 60
           && limitValue(cmdCut) == nil && limitValue(cmdLowOn) == nil && limitValue(0x80 + 39) == nil && limitValue(0x80 + 101) == nil, "intel: limit bytes never clash with the other commands")
    expect(bottomRange(50).lowerBound >= limitBytes.lowerBound && limitValue(limitCommand(bottomRange(50).lowerBound)) == UInt8(bottomRange(50).lowerBound), "intel: the lowest sailing bottom fits a limit byte")
    expect([cmdCut, cmdOn, cmdDeep, cmdLowOn, cmdLowOff, cmdLedDark, cmdLedNormal].allSatisfy { $0 < cmdLimitBase }, "intel: every older command is under the limit bytes")
    expect(helperLimitResult(replyDone) == .ok && helperLimitResult(nil) == .noHelper(old: false) && helperLimitResult(replyOn) == .noHelper(old: true)
           && helperLimitResult(replyBusy) != .ok && helperLimitResult(replyErr) != .ok, "intel: the helper's replies")
    var ic = Carry()
    let i60 = decide(&ic, level: 70, external: true, tempF: nil, scheduled: nil, limit: 60, sailing: false, bottom: 55, heat: false, calibDue: false, floor: 0, lid: false)
    expect(i60.plan == Plan(mac: 60, cut: false), "intel: 60% is the helper's limit, no charger switch")
    ic = Carry()
    expect(decide(&ic, level: 70, external: true, tempF: 99, scheduled: nil, limit: 80, sailing: false, bottom: 75, heat: true, calibDue: false, floor: 0, lid: false).plan == Plan(mac: 70, cut: false),
           "intel: heat pause holds the limit at the level, on the charger")
    ic = Carry(resting: true, lastTop: 90)
    expect(decide(&ic, level: 88, external: true, tempF: nil, scheduled: nil, limit: 90, sailing: true, bottom: 70, heat: false, calibDue: false, floor: 0, lid: false).plan == Plan(mac: 70, cut: false),
           "intel: sailing rests through the limit, not the charger switch")
    ic = Carry(); _ = decide(&ic, level: 70, external: true, tempF: nil, scheduled: nil, limit: 60, sailing: false, bottom: 55, heat: false, calibDue: false, autoRunDown: true, holding: true, floor: 0, lid: false)
    expect(ic.runDown == 60, "intel: the automatic run down works under 80 too (no charger switch brings it down there)")
    expect(statusText(Snapshot(level: 92, plugged: true, charging: true, limit: 80, mode: .needsHelper)) == "Charging" && notHolding(.needsHelper) && !isCharging(Snapshot(level: 92, plugged: true, charging: true, limit: 80, mode: .needsHelper)),
           "intel without the helper: level only, plain Quit")
    // One step's decision (decide), the part of the work queue's step that has no hardware in it.
    func step(_ c: inout Carry, _ level: Int?, plugged: Bool? = true, sched: Int? = nil, limit: Int = 80, due: Bool = false, lid: Bool = false) -> (top: Int, plan: Plan, filling: Bool, calibDone: Bool) {
        decide(&c, level: level, external: plugged, tempF: nil, scheduled: sched, limit: limit, sailing: false, bottom: 75, heat: false, calibDue: due, lid: lid)
    }
    var c = Carry(fullOnce: true)
    expect(step(&c, 99).filling && c.fullOnce && step(&c, 100).plan == Plan(mac: 80, cut: false) && !c.fullOnce, "decide: charge to full once ends at 100%")
    c = Carry(); c.resting = true; c.lastTop = 80
    expect(step(&c, 85, sched: 100).top == 100 && !c.resting && c.lastTop == 100, "decide: a schedule's limit wins and charges up to it first")
    c = Carry()
    _ = step(&c, 80, sched: 90, due: true); expect(c.calib == 0, "decide: a due calibration waits while a schedule runs")
    _ = step(&c, 80, plugged: false, due: true); expect(c.calib == 0, "decide: a due calibration waits for the charger")
    _ = step(&c, 80, due: true); expect(c.calib == 1, "decide: a due calibration starts on the charger")
    _ = step(&c, 100); expect(c.calib == 2 && step(&c, 50).plan.cut, "decide: calibration step 2 runs on battery")
    _ = step(&c, calibFloor); let fin = step(&c, 100); expect(c.calib == 0 && fin.calibDone, "decide: calibration finishes")
    c = Carry(runDown: 80)
    expect(step(&c, 90).plan.cut && c.runDown == 80, "decide: run down cuts power")
    expect(!step(&c, 90, lid: true).plan.cut && c.runDown == nil, "decide: run down ends when the lid closes")
    c = Carry(runDown: 80); _ = step(&c, 90, plugged: false); expect(c.runDown == nil, "decide: run down ends when unplugged")
    c = Carry(runDown: 80); _ = step(&c, 80); expect(c.runDown == nil, "decide: run down ends at its level")
    c = Carry(resting: true, pausedAt: 70, lastTop: 80); _ = step(&c, nil); expect(c.resting && c.pausedAt == 70, "decide: an unreadable level changes neither state")
    // Mockup v4: the automatic run down.
    func auto(_ c: inout Carry, _ level: Int?, plugged: Bool? = true, sched: Int? = nil, limit: Int = 80, holding: Bool = true, macCal: Bool = false, lid: Bool = false) -> Plan {
        decide(&c, level: level, external: plugged, tempF: nil, scheduled: sched, limit: limit, sailing: false, bottom: 75, heat: false, calibDue: false,
               autoRunDown: true, holding: holding, macCal: macCal, lid: lid).plan
    }
    c = Carry(); expect(auto(&c, 94).cut && c.runDown == 80 && c.autoRun, "auto run down: starts above the limit on the charger while holding")
    expect(auto(&c, 85).cut && c.runDown == 80 && auto(&c, 80) == Plan(mac: 80, cut: false) && c.runDown == nil && !c.autoRun, "auto run down: ends at the limit")
    expect(!auto(&c, 80).cut && c.runDown == nil, "auto run down: at the limit nothing starts")
    c = Carry(); _ = step(&c, 94); expect(c.runDown == nil, "auto run down: the switch off never starts it")
    c = Carry(); expect(!auto(&c, 94, plugged: false).cut && c.runDown == nil, "auto run down: waits for the charger")
    c = Carry(); expect(!auto(&c, 94, holding: false).cut && c.runDown == nil, "auto run down: only while Charge Keeper holds")
    c = Carry(); expect(!auto(&c, 94, lid: true).cut && c.runDown == nil, "auto run down: never with the lid closed")
    c = Carry(); _ = auto(&c, 94, sched: 90); expect(c.runDown == nil, "auto run down: waits while a schedule runs")
    c = Carry(fullOnce: true); _ = auto(&c, 94); expect(c.runDown == nil && c.fullOnce, "auto run down: waits during Charge to Full Once")
    _ = auto(&c, 100); expect(!c.fullOnce && c.runDown == 80, "auto run down: starts once Charge to Full Once is done")
    c = Carry(calib: 3); _ = auto(&c, 94); expect(c.runDown == nil && c.calib == 3, "auto run down: waits during a calibration")
    c = Carry(); _ = auto(&c, 94, macCal: true); expect(c.runDown == nil, "auto run down: waits while macOS charges to full on its own")
    c = Carry(); _ = auto(&c, 70, limit: 60); expect(c.runDown == nil, "auto run down: under 80 the charger switch already brings it down")
    c = Carry(); _ = auto(&c, 94); c.runDown = nil; c.autoHeld = true  // Stop This Time
    expect(!auto(&c, 94).cut && !auto(&c, 80).cut && c.runDown == nil, "auto run down: Stop This Time holds it off at and above the limit")
    _ = auto(&c, 79); expect(!c.autoHeld && auto(&c, 85).cut && c.runDown == 80, "auto run down: once under the limit again it can start again")
    c = Carry(); _ = auto(&c, 94); _ = auto(&c, 94, plugged: false); expect(c.runDown == nil && !c.autoRun, "auto run down: unplugging ends it")
    c = Carry(); _ = auto(&c, 94); expect(!auto(&c, 92, sched: 100).cut && c.runDown == nil, "auto run down: a schedule starting ends it")
    c = Carry(); _ = auto(&c, 94); expect(!auto(&c, 92, macCal: true).cut && c.runDown == nil, "auto run down: macOS charging to full ends it")
    c = Carry(); _ = auto(&c, 94); expect(auto(&c, 92, limit: 90).cut && c.runDown == 90, "auto run down: a new limit restarts it to that limit")
    c = Carry(); _ = auto(&c, 94); expect(!step(&c, 92).plan.cut && c.runDown == nil, "auto run down: switching it off ends it")
    c = Carry(runDown: 80); expect(auto(&c, 92, sched: 100).cut && c.runDown == 80, "a run down started by hand is left to the user")
    expect(statusText(Snapshot(level: 88, plugged: true, charging: false, limit: 80, mode: .holding, cut: true, runDown: 80, autoRun: true)) == "On battery, down to 80%", "auto run down status")
    var r = Snapshot(level: 88, plugged: true, charging: false, limit: 80, mode: .holding, cut: true, runDown: 80)
    expect(statusText(r) == "On battery, down to 80%" && !isCharging(r), "run down status")
    r = Snapshot(level: 41, plugged: true, charging: false, limit: 80, mode: .holding, cut: true, calib: 2)
    expect(statusText(r) == "Calibrating, step 2 of 3", "calibration status")
    expect(statusText(Snapshot(level: 94, plugged: true, charging: false, limit: 80, mode: .holding)) == "Above 80%, not charging", "above the limit on the charger")
    // Battery health (mockup v4). John's M2 on 2026-11-21: 4045 / 4563 mAh, System Settings says 89%.
    let m2: [String: Any] = ["MaxCapacity": 100, "CycleCount": 190, "BatteryData": ["AppleRawMaxCapacity": 4045, "FullChargeCapacity": 4045, "DesignCapacity": 4563, "NominalChargeCapacity": 4172]]
    expect(healthPercent(m2) == 89, "health: Apple chip, from BatteryData, rounded as System Settings (not NominalChargeCapacity)")
    expect(healthPercent(["MaxCapacity": 100, "BatteryData": ["FullChargeCapacity": 4045, "DesignCapacity": 4563]]) == 89, "health: FullChargeCapacity when the raw key is missing")
    expect(healthPercent(["MaxCapacity": 5103, "DesignCapacity": 5800, "AppleRawMaxCapacity": 5103]) == 88 && healthPercent(["MaxCapacity": 5103, "DesignCapacity": 5800]) == 88, "health: Intel, mAh at the top level")
    expect(healthPercent(["MaxCapacity": 100]) == nil && healthPercent(["MaxCapacity": 100, "DesignCapacity": 0]) == nil, "health: a percent MaxCapacity or no design capacity is not a reading")
    expect(healthPercent(["BatteryData": ["AppleRawMaxCapacity": 4700, "DesignCapacity": 4563]]) == 100, "health: a new battery over its design shows 100%")
    expect(!needsService(health: nil, condition: nil) && !needsService(health: "Good", condition: "") && needsService(health: "Good", condition: "Check Battery")
           && needsService(health: nil, condition: "Permanent Battery Failure") && needsService(health: "Poor", condition: nil), "health: service only when macOS says so")
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
    s = hold; s.limit = 85; s.level = 93; s.charging = true; s.calibrating = true
    expect(statusText(s) == "macOS calibrating" && isCharging(s), "macOS charging to full past the limit")
    s.charging = false; s.level = 100
    expect(statusText(s) == "macOS calibrating" && !isCharging(s), "calibration done, still above the limit")
    s.heatOn = true; s.paused = true
    expect(statusText(s) == "macOS calibrating", "calibrating wins over a heat pause (macOS has set the limit aside)")
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
    expect(raiseNeedsReset(cur: LimitState(enabled: true, limit: 80), target: 85), "raising a limit that is on (sailing off): off first, or it never charges")
    expect(!raiseNeedsReset(cur: on85, target: 80) && !raiseNeedsReset(cur: LimitState(enabled: false, limit: 100), target: 85), "lowering, or a limit that is off: no reset")
    expect(!changedOutside(cur: LimitState(enabled: false, limit: 85), held: on85, reassert: true), "turned off just after wake: set back, not a clash")
    expect(shouldRegisterLoginItem(path: "/Applications/Charge Keeper.app", asked: false), "login item: installed copy, first time")
    expect(wantsCut(mode: .holding, level: 70, planCut: true) && wantsCut(mode: .fullOnce, level: 70, planCut: true), "cut: holding asks for it")
    expect(!wantsCut(mode: .failed("x"), level: 70, planCut: true), "cut: a failed step gives power back")
    expect(!wantsCut(mode: .holding, level: nil, planCut: true), "cut: an unreadable level never cuts")
    expect(!wantsCut(mode: .steppedAside, level: 70, planCut: true) && !wantsCut(mode: .holding, level: 70, planCut: false), "cut: not holding, or no cut planned")
    expect(cutsNow(want: true, aldente: false, lid: false), "cut: wanted and clear")
    expect(!cutsNow(want: true, aldente: true, lid: false) && !cutsNow(want: true, aldente: false, lid: true), "cut: AlDente or a closed lid gives power back")
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
    featureSelftest(expect)
    helperSelftest(expect)
    endToEndSelftest(expect)
    print(bad == 0 ? "selftest ok" : "selftest FAILED")
    return bad == 0 ? 0 : 1
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "--watchdog": runWatchdog(args)
case "--helper", "--helper-fake": runHelper(args)
case "--selftest": exit(selftest())
case "--test-client":  // the self-test's stand-in app: cut power through the helper at <socket>, report the answer, wait to be killed
    guard args.count == 3 else { exit(2) }
    let c = ChargerClient(path: args[2])
    var r = c.send(byte: cmdCut) ?? 0
    write(1, &r, 1)
    while true { pause() }
case "--render": exit(MainActor.assumeIsolated { renderAll(to: args.count > 2 ? args[2] : "keeper-render") } ? 0 : 1)
case "--probe":
    guard let m = MCL() else { print("PowerUI client could not be created"); exit(1) }
    let st = m.state()
    print("mcl: supported=\(m.supported) enabled=\(st.map { "\($0.enabled)" } ?? "?") limit=\(st.map { "\($0.limit)" } ?? "?")")
    let bt = battery()
    print("charger switch: \(chargerSwitch()?.key ?? "none found")  magsafe light: \(SMCSwitch(key: "ACLC") != nil)")
    print("battery: level=\(bt.current.map(String.init) ?? "?") temperature=\(bt.tempF.map(degrees) ?? "?")")
    let h = readHealth()
    print("health: max capacity=\(h.maxPercent.map { "\($0)%" } ?? "?") cycles=\(h.cycles.map(String.init) ?? "?") service=\(h.service)")
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
