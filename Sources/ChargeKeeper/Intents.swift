// Mockup v4: real actions in the Shortcuts app (App Intents), each going through the same Keeper call as its chargekeeper:// link.
// The type names are what saved shortcuts store: never rename one. Their metadata (Metadata.appintents) is made at build time
// by scripts/make-app.sh, as plain `swift build` does not make it.
import AppIntents
import Foundation

// Set at launch (StatusController). An action that launches Charge Keeper may run before launch has finished: it waits a little.
@MainActor var runningKeeper: Keeper?

struct KeeperNotRunning: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "Charge Keeper is not running. Open it, then run the shortcut again." }
}

@MainActor private func keeper() async throws -> Keeper {
    for _ in 0..<50 {
        if let k = runningKeeper { return k }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw KeeperNotRunning()
}

struct SetChargeLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Charge Limit"
    static let description = IntentDescription("Sets the level Charge Keeper charges up to, from 50% to 100% in steps of 5.")
    @Parameter(title: "Limit", inclusiveRange: (50, 100)) var limit: Int
    static var parameterSummary: some ParameterSummary { Summary("Set charge limit to \(\.$limit)%") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let v = clampLimit(limit + 2)  // the nearest step of 5
        try await keeper().open(.limit(v))
        return .result(dialog: "Charge limit set to \(v)%.")
    }
}

struct ChargeToFullOnceIntent: AppIntent {
    static let title: LocalizedStringResource = "Charge to Full Once"
    static let description = IntentDescription("Charges to 100% once, then goes back to your limit by itself.")
    @MainActor func perform() async throws -> some IntentResult { try await keeper().open(.full); return .result() }
}

struct GoBackToLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Go Back to My Limit"
    static let description = IntentDescription("Stops a Charge to Full Once and holds at your limit again.")
    @MainActor func perform() async throws -> some IntentResult { try await keeper().backToLimit(); return .result() }
}

struct RunDownIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Down to My Limit"
    static let description = IntentDescription("Runs the Mac on its battery down to your limit while the charger stays plugged in.")
    @MainActor func perform() async throws -> some IntentResult { try await keeper().open(.runDown); return .result() }
}

struct SetHeatPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Heat Pause On or Off"
    static let description = IntentDescription("Stops charging while the battery is warm.")
    @Parameter(title: "Heat Pause", default: true, displayName: Bool.IntentDisplayName(true: "On", false: "Off")) var on: Bool
    static var parameterSummary: some ParameterSummary { Summary("Turn heat pause \(\.$on)") }
    @MainActor func perform() async throws -> some IntentResult { try await keeper().open(.heat(on)); return .result() }
}

struct SetSailingRangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Sailing Range On or Off"
    static let description = IntentDescription("Lets the battery drift down a little before charging again.")
    @Parameter(title: "Sailing Range", default: true, displayName: Bool.IntentDisplayName(true: "On", false: "Off")) var on: Bool
    static var parameterSummary: some ParameterSummary { Summary("Turn sailing range \(\.$on)") }
    @MainActor func perform() async throws -> some IntentResult { try await keeper().open(.sailing(on)); return .result() }
}

struct BatteryStatusEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Battery Status"
    @Property(title: "Battery Level") var level: Int
    @Property(title: "Charging") var charging: Bool
    @Property(title: "Charge Limit") var limit: Int
    @Property(title: "Maximum Capacity") var maxCapacity: Int
    @Property(title: "Charge Cycles") var cycles: Int
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(level)%, \(charging ? "charging" : "not charging"), limit \(limit)%") }
    init() {}
}

struct GetBatteryStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Battery Status"
    static let description = IntentDescription("Hands back the battery level, whether it is charging, the limit in force, the maximum capacity and the charge cycles.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<BatteryStatusEntity> & ProvidesDialog {
        let s = try await keeper().snap
        let b = battery()  // fresh, not the last 30-second step
        let h = s.health ?? readHealth()
        var e = BatteryStatusEntity()
        e.level = b.current ?? s.level
        e.charging = b.charging ?? s.charging
        e.limit = s.limit
        e.maxCapacity = h.maxPercent ?? 0  // 0: not known
        e.cycles = h.cycles ?? 0
        return .result(value: e, dialog: "\(e.level)%, \(e.charging ? "charging" : "not charging"), limit \(e.limit)%.")
    }
}

// The Settings > Shortcuts list (mockup v4), in the order drawn.
let shortcutActions: [(name: String, hint: String)] = [
    ("Set Charge Limit", "50% to 100%"), ("Charge to Full Once", "then back to the limit"), ("Go Back to My Limit", "stops a full charge"),
    ("Run Down to My Limit", "on battery, charger in"), ("Turn Heat Pause On or Off", ""), ("Turn Sailing Range On or Off", ""),
    ("Get Battery Status", "level, charging, limit"),
]
