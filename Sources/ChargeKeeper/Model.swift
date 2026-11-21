// The app's state as the screens see it, and the pure rules over it (status line, limits, charging test, login item).
import Foundation
import ServiceManagement

// foreign: the Mac's limit was already on; steppedAside: it was changed while we held; macLimit: the user chose the Mac's own limit.
enum Mode: Equatable { case starting, holding, fullOnce, foreign, steppedAside, macLimit, unsupported, failed(String) }

struct Snapshot: Equatable {
    var level = 0
    var plugged = false
    var charging = false
    var limit = 80
    var mode = Mode.starting
    var mac: LimitState? = nil  // the Mac's own setting, read only while Charge Keeper is not holding
    var cut = false  // under 80: the charger's power is switched off, the Mac runs on its battery
    var cutNote: CutNote? = nil  // under 80, but the charger cannot be switched: the Mac's own 80 holds instead
    var heatOn = false, sailing = false
    var bottom = 75  // the sailing range's bottom ("Charge again below")
    var tempF: Double? = nil
    var paused = false  // heat pause in effect: charging stopped because the battery is warm
    var resting = false  // the top was reached, waiting for the level to come down to the bottom
    var calibrating = false  // macOS has set our limit aside for a while to charge to full and re-measure the battery
    // Mockup v3
    var runDown: Int? = nil  // running on battery down to this level, charger plugged in
    var autoRun = false  // that run down started by itself (mockup v4)
    var calib = 0  // Charge Keeper's own calibration cycle: its step 1...3, 0 = not running
    var scheduled: Scheduled? = nil  // a schedule sets the limit now (limit above is then the schedule's)
    var lowPower = false
    var keepsOnQuit = false  // quitting now leaves the limit on ("Keep my limit")
    var helperOld = false  // the installed helper predates low power, the MagSafe light and the deep run down
    var settings = KeeperSettings()
}

struct Scheduled: Equatable { var name: String; var until: Date; var back: Int }
// What the Settings window shows and changes; the Keeper owns them on its work queue.
struct KeeperSettings: Equatable {
    var schedules: [Schedule] = []
    var keepOnQuit = false
    var led = LedMode.normal
    var calibratedAt: Date? = nil
    var calibEvery = 0  // months; 0 = no calibration schedule
    var calibSince: Date? = nil  // when the calibration schedule was set or a scheduled run was cancelled
    var autoRunDown = false  // mockup v4: "Run down to my limit by itself"
    var look = Look()
}

// Mockup v4, Settings > Look: the menu-bar icon and which buttons and switches the panel shows. Hidden ones keep working.
struct Look: Codable, Equatable {
    var icon = IconStyle.numberInBattery
    var sweep = true  // "Charging animation"
    var full = true, runDown = true, heat = true, sailing = true, lowPower = true
}

enum CutNote: Equatable { case noHelper, aldente, otherApp, lidClosed, oldHelper }

// The level Charge Keeper really holds: under 80 without the charger switch, the Mac's own limit stops at 80.
func holdLevel(_ s: Snapshot) -> Int { s.cutNote == nil ? s.limit : max(s.limit, macFloor) }

// The panels that show the Mac's own limit instead of Charge Keeper's slider.
func showsChoice(_ m: Mode) -> Bool { m == .foreign || m == .steppedAside }
// Charge Keeper has let the Mac's limit be (Quit changes nothing then).
func notHolding(_ m: Mode) -> Bool { showsChoice(m) || m == .macLimit }

let limitRange = 50...100  // the approved mockup's slider; 80 and up is the Mac's own limit, under 80 the charger switch (Charger.swift)

func clamp5(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(r.upperBound, max(r.lowerBound, v / 5 * 5)) }
func clampLimit(_ v: Int) -> Int { clamp5(v, limitRange) }
// The sailing range's bottom: at least 5 under the top; the slider always spans at least one step (40...45 under a top of 50).
func bottomRange(_ limit: Int) -> ClosedRange<Int> { min(limitRange.lowerBound, limit - 2 * cutBand)...(limit - cutBand) }
func clampBottom(_ v: Int, limit: Int) -> Int { clamp5(v, bottomRange(limit)) }
func degrees(_ f: Double) -> String { "\(Int(f.rounded()))°F" }

func statusText(_ s: Snapshot) -> String {
    switch s.mode {
    case .starting: return "Starting"
    case .unsupported: return "This Mac has no charge limit"
    case .foreign: return "Not holding yet"
    case .steppedAside: return "Stepped aside"
    case .macLimit: return s.mac.map { $0.enabled ? "Mac's limit: \($0.limit)%" : "No limit on" } ?? "Mac's limit"
    case .failed: return "Could not set the limit"
    case .holding, .fullOnce:
        if s.calib > 0 { return "Calibrating, step \(s.calib) of 3" }
        if let t = s.runDown { return "On battery, down to \(t)%" }
        if s.calibrating { return "macOS calibrating" }  // before the heat pause: at 80 and up it works through the Mac's limit, which macOS has set aside
        if s.paused { return "Paused, battery warm" }
        if s.mode == .holding && s.sailing && s.resting && s.level != s.limit { return "Resting down to \(s.bottom)%" }
        if s.cut { return s.level > s.limit ? "Coming down to \(s.limit)%" : "Holding at \(s.limit)%" }
        if !s.plugged { return "On battery" }
        if s.mode == .fullOnce { return "Charging to full, once" }
        let h = holdLevel(s)
        return s.charging && s.level < h ? "Charging to \(h)%" : s.level > h ? "Above \(h)%, not charging" : "Holding at \(h)%"
    }
}

// Actually charging (same test as the status line): this is what drives the green movement.
func isCharging(_ s: Snapshot) -> Bool {
    s.plugged && s.charging && !s.cut && (s.mode == .fullOnce || (s.mode == .holding && (s.level < holdLevel(s) || s.calibrating)))
}

// The animation is one number, 0...1 (see sweepAmount): the icon's green and the panel bar's stretch both follow it.
let stillSweep = 0.5  // Reduce Motion: a still picture of "charging"
func iconFill(_ sweep: Double) -> Double { 0.07 + 0.93 * sweep }  // the icon starts as a sliver, never empty

// The charger cut, as pure rules (the only path that can leave power off). Only a holding or charge-to-full step with a
// readable level may want a cut; a failed step or an unreadable level gives power back. AlDente or a closed lid: never cut.
func wantsCut(mode: Mode, level: Int?, planCut: Bool) -> Bool { (mode == .holding || mode == .fullOnce) && level != nil && planCut }
func cutsNow(want: Bool, aldente: Bool, lid: Bool) -> Bool { want && !aldente && !lid }

// Start with the Mac, once, and only for the copy in /Applications (a build folder copy must not become a login item).
// If the user switches it off in System Settings it stays off: the question is asked a single time.
func shouldRegisterLoginItem(path: String, asked: Bool) -> Bool { !asked && path.hasPrefix("/Applications/") }

func registerLoginItemOnce() {
    let d = UserDefaults.standard
    guard shouldRegisterLoginItem(path: Bundle.main.bundlePath, asked: d.bool(forKey: "loginItemAsked")) else { return }
    do { try SMAppService.mainApp.register(); d.set(true, forKey: "loginItemAsked") } catch {}  // on failure, tried again next launch
}
