// Entry. No argument = the menu-bar app. The flags below are for the safety watchdog, emergencies and checks.
//   --restore    put the Mac's charge limit back to off / 100 (also works if the app is not running)
//   --probe      read-only: is the limit supported, on or off, which level
//   --selftest   pure logic checks, no hardware
//   --render <folder>   draw the panel and icon to PNG files off-screen (no window, no charge-limit access)
import Foundation
import AppKit

private func s0(charging: Bool, level: Int, plugged: Bool = true) -> Snapshot { Snapshot(level: level, plugged: plugged, charging: charging, limit: 80, mode: .holding) }

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
    expect(shouldRegisterLoginItem(path: "/Applications/Charge Keeper.app", asked: false), "login item: installed copy, first time")
    expect(!shouldRegisterLoginItem(path: "/Applications/Charge Keeper.app", asked: true), "login item: asked only once")
    expect(!shouldRegisterLoginItem(path: "/Users/x/charge-keeper/build/Charge Keeper.app", asked: false), "login item: never for a build-folder copy")
    expect(isCharging(s0(charging: true, level: 62)) && !isCharging(s0(charging: true, level: 80)) && !isCharging(s0(charging: false, level: 62)) && !isCharging(s0(charging: true, level: 62, plugged: false)), "animation only while really charging")
    expect(sweepAmount(0) == 0 && sweepAmount(1.6) == 1 && sweepAmount(1.9) == 1 && sweepAmount(0.8) > sweepAmount(0.4) && abs(sweepAmount(0.8) - 0.5) < 1e-9, "sweep grows, rests, restarts")
    print(bad == 0 ? "selftest ok" : "selftest FAILED")
    return bad == 0 ? 0 : 1
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "--watchdog": runWatchdog(args)
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
    // A second copy would switch off the first copy's live limit at start-up, so it just leaves.
    if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 { exit(0) }
    KeeperApp.main()
}
