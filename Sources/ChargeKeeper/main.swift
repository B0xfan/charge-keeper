// Entry. No argument = the menu-bar app. The flags below are for the safety watchdog, emergencies and checks.
//   --restore    put the Mac's charge limit back to off / 100 (also works if the app is not running)
//   --probe      read-only: is the limit supported, on or off, which level
//   --selftest   pure logic checks, no hardware
import Foundation

func selftest() -> Int32 {
    var bad = 0
    func expect(_ c: Bool, _ n: String) { if !c { print("FAIL \(n)"); bad += 1 } }
    let off = State(enabled: false, limit: 100)
    expect(State(enabled: false, limit: 90).matches(off) && !State(enabled: true, limit: 100).matches(off), "off compares only the switch")
    expect(State(enabled: true, limit: 90).matches(State(enabled: true, limit: 90)) && !State(enabled: true, limit: 85).matches(State(enabled: true, limit: 90)), "on compares the level")
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
    print(bad == 0 ? "selftest ok" : "selftest FAILED")
    return bad == 0 ? 0 : 1
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "--watchdog": runWatchdog(args)
case "--selftest": exit(selftest())
case "--probe":
    guard let m = MCL() else { print("PowerUI client could not be created"); exit(1) }
    let st = m.state()
    print("mcl: supported=\(m.supported) enabled=\(st.map { "\($0.enabled)" } ?? "?") limit=\(st.map { "\($0.limit)" } ?? "?")")
case "--restore":
    guard let m = MCL() else { print("PowerUI client could not be created"); exit(2) }
    let ok = restore(m, State(enabled: false, limit: 100))
    if ok { try? FileManager.default.removeItem(at: markerURL) }
    print("restore: \(ok) state=\(String(describing: m.state()))")
    exit(ok ? 0 : 1)
default: KeeperApp.main()
}
