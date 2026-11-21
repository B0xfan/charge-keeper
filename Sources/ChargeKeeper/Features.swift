// Mockup v3: schedules, run down on battery, calibration cycle, MagSafe light, links. Pure rules only;
// Keeper (App.swift) applies them and the helper (Charger.swift) does the root-only parts.
import Foundation

// MARK: - schedules

// days empty = once (from and until are full dates). Otherwise Calendar weekdays 1...7 (1 = Sunday) and only the time of day
// of from and until counts; until at or before from runs past midnight.
struct Schedule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var limit: Int
    var on = true
    var days: Set<Int> = []
    var from: Date
    var until: Date
}

let weekdays: Set<Int> = [2, 3, 4, 5, 6], everyDay: Set<Int> = Set(1...7)

// When the occurrence running at `now` ends, or nil when the schedule is not running.
func occurrenceEnd(_ s: Schedule, now: Date, cal: Calendar = .current) -> Date? {
    guard s.on else { return nil }
    if s.days.isEmpty { return s.from <= now && now < s.until ? s.until : nil }
    func mins(_ d: Date) -> Int { let c = cal.dateComponents([.hour, .minute], from: d); return c.hour! * 60 + c.minute! }
    let start = mins(s.from), end = mins(s.until), n = mins(now)
    let today = cal.component(.weekday, from: now), yesterday = today == 1 ? 7 : today - 1
    let midnight = cal.startOfDay(for: now)
    func at(_ m: Int, plusDays: Int) -> Date { cal.date(byAdding: .minute, value: m, to: cal.date(byAdding: .day, value: plusDays, to: midnight)!)! }
    if start < end { return s.days.contains(today) && start <= n && n < end ? at(end, plusDays: 0) : nil }
    if s.days.contains(today) && n >= start { return at(end, plusDays: 1) }  // overnight: started today, ends tomorrow
    if s.days.contains(yesterday) && n < end { return at(end, plusDays: 0) }  // overnight: started yesterday
    return nil
}

// The schedule in charge now: the highest limit among those running (so a trip is never cut short), skipped occurrences left out.
func activeSchedule(_ list: [Schedule], now: Date, skipped: [UUID: Date], cal: Calendar = .current) -> (Schedule, Date)? {
    list.compactMap { s in occurrenceEnd(s, now: now, cal: cal).flatMap { skipped[s.id] == $0 ? nil : (s, $0) } }.max { $0.0.limit < $1.0.limit }
}

// A once schedule that has ended turns itself off.
func expired(_ s: Schedule, now: Date) -> Bool { s.on && s.days.isEmpty && now >= s.until }

// MARK: - calibration cycle

// 1 charge to full, 2 run down to calibFloor on battery (charger plugged in), 3 charge to full, then back to the limit.
let calibFloor = 15
// The next step (nil: done), or the same one. An unreadable level never moves it.
func nextCalib(_ step: Int, level: Int?) -> Int? {
    guard let l = level else { return step }
    switch step {
    case 1: return l >= 100 ? 2 : 1
    case 2: return l <= calibFloor ? 3 : 2
    default: return l >= 100 ? nil : 3
    }
}

// Calibration on a schedule: every `months` months (0 = off), counted from the last run or from when it
// was last set or cancelled, whichever is later. It starts the first time it is due while Charge Keeper holds the limit on the charger.
let calibEveryChoices = [0, 1, 2, 3]
func nextCalibration(months: Int, last: Date?, since: Date?, cal: Calendar = .current) -> Date? {
    guard months > 0, let from = [last, since].compactMap({ $0 }).max() else { return nil }
    return cal.date(byAdding: .month, value: months, to: from)
}

// MARK: - one step's decision

// The state carried from one step to the next (Keeper's work queue owns it).
struct Carry: Equatable {
    var fullOnce = false  // charge to full once, until 100
    var calib = 0  // the calibration cycle's step 1...3, 0 = not running
    var runDown: Int? = nil  // on battery down to this level, charger plugged in
    var resting = false  // see nextResting
    var pausedAt: Int? = nil  // see heatStep
    var lastTop = 0  // the limit in force at the last step (a schedule's or the slider's)
    var autoRun = false  // the run down now going was started by itself (mockup v4)
    var autoHeld = false  // "Stop This Time": no new automatic run down until the level is under the limit again
}

// The pure part of a step: from one battery reading, move the carried state on and work out the limit in force (top) and the plan.
// scheduled: the running schedule's limit. calibDue: a calibration schedule is due and the last step held the limit.
// autoRunDown: the "Run down to my limit by itself" switch; holding: the last step held the limit; macCal: macOS is charging
// to full on its own. floor: the lowest limit the Mac holds by itself (macFloor; 0 on Intel, where the helper sets any limit).
func decide(_ c: inout Carry, level: Int?, external: Bool?, tempF: Double?, scheduled: Int?, limit: Int, sailing: Bool, bottom: Int,
            heat: Bool, calibDue: Bool, autoRunDown: Bool = false, holding: Bool = false, macCal: Bool = false, floor: Int = macFloor,
            lid: @autoclosure () -> Bool) -> (top: Int, plan: Plan, filling: Bool, calibDone: Bool) {
    if c.fullOnce && (level ?? 0) >= 100 { c.fullOnce = false }  // the one-off ends by itself; before the plan, which depends on it
    let top = scheduled.map(clampLimit) ?? limit
    if top != c.lastTop { c.resting = false; c.lastTop = top }  // a new top (schedule start or end): charge up to it first, as setLimit does
    // A due calibration starts only on the charger, with nothing else running.
    if c.calib == 0, calibDue, c.runDown == nil, !c.fullOnce, scheduled == nil, external == true { c.calib = 1 }
    var done = false
    if c.calib > 0 { c.calib = nextCalib(c.calib, level: level) ?? 0; done = c.calib == 0 }
    // An automatic run down ends once it would no longer start: its switch is off, a schedule or macOS's own charge to full has taken over, or the limit moved.
    if c.autoRun, !autoRunDown || scheduled != nil || macCal || c.runDown != top { c.runDown = nil }
    // Run down ends at its level, when unplugged, or when the lid closes (cutting power could put the Mac to sleep).
    if let t = c.runDown, level.map({ $0 <= t }) ?? false || external != true || lid() { c.runDown = nil }
    let filling = c.fullOnce || c.calib == 1 || c.calib == 3
    let rb = restBottom(limit: top, sailing: sailing, bottom: clampBottom(bottom, limit: top), floor: floor)
    if let lv = level {  // an unreadable level changes neither state
        c.pausedAt = heatStep(on: heat, tempF: tempF, level: lv, pausedAt: c.pausedAt)
        c.resting = nextResting(level: lv, top: top, bottom: rb, resting: c.resting)
    }
    var p = plan(level: level ?? 0, limit: top, bottom: rb, resting: c.resting, fullOnce: filling, pausedAt: c.pausedAt, floor: floor)
    if c.runDown == nil { c.autoRun = false }
    if let lv = level, lv < top { c.autoHeld = false }  // "Stop This Time" lasts until the level is under the limit again
    // The automatic run down: the Run Down button pressed by itself, above the limit in force, on the charger, while holding,
    // with nothing else running. Not when the plan already cuts (under 80 the charger switch brings it down by itself).
    if autoRunDown, holding, c.runDown == nil, !c.autoHeld, c.calib == 0, !c.fullOnce, scheduled == nil, !macCal, external == true,
       !p.cut, let lv = level, lv > top, !lid() {
        c.runDown = top; c.autoRun = true
    }
    if c.runDown != nil || c.calib == 2 { p.cut = true }  // on battery with the charger plugged in
    return (top, p, filling, done)
}

// An automatic run down the charger could not follow (no helper, AlDente running, another app's cut: the helper did not
// cut) ends quietly; the next step tries again, so it starts once the cause is gone. True when it ended one.
func endUnfollowedAutoRun(_ c: inout Carry, cutNow: Bool) -> Bool {
    guard c.autoRun, !cutNow else { return false }
    c.runDown = nil; c.autoRun = false
    return true
}

// MARK: - MagSafe light

enum LedMode: Int, CaseIterable { case normal, offWhileHeld, off }
// True: the light should be dark now. Only on the charger (off it, there is no light to change).
func ledDark(_ m: LedMode, plugged: Bool, charging: Bool) -> Bool { plugged && (m == .off || m == .offWhileHeld && !charging) }

// MARK: - links

enum LinkAction: Equatable { case limit(Int), full, runDown, heat(Bool), sailing(Bool), lowPower(Bool), calibration(Bool) }
// chargekeeper://limit/80, chargekeeper://full, chargekeeper://rundown, and on/off for every switch: chargekeeper://heat/on,
// chargekeeper://sailing/off, chargekeeper://lowpower/on, chargekeeper://calibration/on (starts it; off cancels it). Anything else is ignored.
let linkExamples = ["chargekeeper://limit/80", "chargekeeper://full", "chargekeeper://rundown", "chargekeeper://heat/on",
                    "chargekeeper://sailing/on", "chargekeeper://lowpower/on", "chargekeeper://calibration/on"]
func linkAction(_ url: URL) -> LinkAction? {
    guard url.scheme?.lowercased() == "chargekeeper" else { return nil }
    let arg = url.lastPathComponent.lowercased()
    let on: Bool? = arg == "on" ? true : arg == "off" ? false : nil
    switch url.host?.lowercased() {
    case "limit": return Int(arg).flatMap { limitRange.contains($0) ? .limit($0) : nil }
    case "full": return .full
    case "rundown": return .runDown
    case "heat": return on.map { .heat($0) }
    case "sailing": return on.map { .sailing($0) }
    case "lowpower": return on.map { .lowPower($0) }
    case "calibration": return on.map { .calibration($0) }
    default: return nil
    }
}
