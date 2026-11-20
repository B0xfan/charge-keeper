// Mockup v3 (John, 2026-11-16): schedules, run down on battery, calibration cycle, MagSafe light, links. Pure rules only;
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

// Calibration on a schedule (John, 2026-11-20): every `months` months (0 = off), counted from the last run or from when it
// was last set or cancelled, whichever is later. It starts the first time it is due while Charge Keeper holds the limit on the charger.
let calibEveryChoices = [0, 1, 2, 3]
func nextCalibration(months: Int, last: Date?, since: Date?, cal: Calendar = .current) -> Date? {
    guard months > 0, let from = [last, since].compactMap({ $0 }).max() else { return nil }
    return cal.date(byAdding: .month, value: months, to: from)
}

// MARK: - MagSafe light

enum LedMode: Int, CaseIterable { case normal, offWhileHeld, off }
// True: the light should be dark now. Only on the charger (off it, there is no light to change).
func ledDark(_ m: LedMode, plugged: Bool, charging: Bool) -> Bool { plugged && (m == .off || m == .offWhileHeld && !charging) }

// MARK: - links

enum LinkAction: Equatable { case limit(Int), full, runDown }
// chargekeeper://limit/80, chargekeeper://full, chargekeeper://rundown. Anything else is ignored.
func linkAction(_ url: URL) -> LinkAction? {
    guard url.scheme?.lowercased() == "chargekeeper" else { return nil }
    switch url.host?.lowercased() {
    case "limit": return Int(url.lastPathComponent).flatMap { limitRange.contains($0) ? .limit($0) : nil }
    case "full": return .full
    case "rundown": return .runDown
    default: return nil
    }
}
