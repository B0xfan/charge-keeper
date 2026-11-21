// Mockup v3 panel 5 and 6: the Settings window and the schedule sheet. Everything set once and left alone lives here.
import SwiftUI
import ServiceManagement

struct SettingsHost: View {
    @ObservedObject var keeper: Keeper
    @State private var login = SMAppService.mainApp.status
    var body: some View {
        SettingsView(s: keeper.snap.settings, change: keeper.update, startCalibration: keeper.startCalibration, canCalibrate: keeper.snap.mode == .holding && keeper.snap.calib == 0,
                     login: login, setLogin: { on in
                         UserDefaults.standard.set(true, forKey: "loginItemAsked")  // the user's own choice: never re-added at launch
                         try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                         login = SMAppService.mainApp.status
                     })
            .onAppear { login = SMAppService.mainApp.status }  // the window is reused; System Settings may have changed it meanwhile
    }
}

enum SettingsTab: Hashable { case general, schedules, care, links }

func limitText(_ v: Int) -> String { "\(v)%" }
func repeatText(_ d: Set<Int>) -> String {
    switch d {
    case []: return "once"
    case everyDay: return "every day"
    case weekdays: return "Mon to Fri"
    default: return d.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }
}
func scheduleLine(_ x: Schedule) -> String {
    let f: Date.FormatStyle = x.days.isEmpty ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute()
    return "charge up to \(limitText(x.limit)) · \(x.from.formatted(f)) to \(x.until.formatted(f)), \(repeatText(x.days))"
}

struct SettingsView: View {
    let s: KeeperSettings
    var change: (@escaping (inout KeeperSettings) -> Void) -> Void = { _ in }
    var startCalibration: () -> Void = {}
    var canCalibrate = true
    var login = SMAppService.Status.notRegistered
    var setLogin: (Bool) -> Void = { _ in }
    @State var tab = SettingsTab.general
    @State private var editing: Schedule?

    var body: some View {
        VStack(spacing: 0) {
            // A segmented switch rather than a TabView: same look, and it draws in the off-screen pictures too.
            Picker("Section", selection: $tab) {
                Text("General").tag(SettingsTab.general); Text("Schedules").tag(SettingsTab.schedules)
                Text("Battery Care").tag(SettingsTab.care); Text("Links").tag(SettingsTab.links)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Form {
                switch tab {
                case .general:
                    Section {
                        Toggle(isOn: Binding(get: { login == .enabled || login == .requiresApproval }, set: setLogin)) {
                            Text("Start at login")
                            Text(login == .requiresApproval ? "Waiting for your OK in System Settings, General, Login Items." : "Opens Charge Keeper when you log in to your Mac.")
                        }
                    }
                    quitSection
                case .schedules: schedulesSection
                case .care: careSection
                case .links: linksSection
                }
            }.formStyle(.grouped)
        }
        .padding(.top, 8).frame(width: 460, height: 400)  // fixed: every tab fits, so the window keeps one size
        .sheet(item: $editing) { x in
            ScheduleEditor(draft: x, isNew: !s.schedules.contains { $0.id == x.id },
                           save: { new in change { st in if let i = st.schedules.firstIndex(where: { $0.id == new.id }) { st.schedules[i] = new } else { st.schedules.append(new) } }; editing = nil },
                           delete: { id in change { $0.schedules.removeAll { $0.id == id } }; editing = nil },
                           cancel: { editing = nil })
        }
    }

    @ViewBuilder private var schedulesSection: some View {
            Section("Schedules") {
                ForEach(s.schedules) { x in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(x.name).bold(); Text(scheduleLine(x)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Edit") { editing = x }.buttonStyle(.link).accessibilityLabel("Edit \(x.name)")
                        Toggle(x.name, isOn: Binding(get: { x.on }, set: { on in change { st in if let i = st.schedules.firstIndex(where: { $0.id == x.id }) { st.schedules[i].on = on } } }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                }
                Picker(selection: Binding(get: { s.calibEvery }, set: { v in change { $0.calibEvery = v; $0.calibSince = Date() } })) {
                    ForEach(calibEveryChoices, id: \.self) { m in Text(m == 0 ? "Off" : m == 1 ? "Every month" : "Every \(m) months").tag(m) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic calibration")
                        Text(nextCalibration(months: s.calibEvery, last: s.calibratedAt, since: s.calibSince).map { $0 <= Date() ? "Due now: starts once plugged in." : "Next: \($0.formatted(date: .abbreviated, time: .omitted)) or later, once plugged in." } ?? "Off: runs only when you press Start Calibration under Battery Care.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Add Schedule…") {
                        let start = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
                        editing = Schedule(name: "", limit: 100, from: start, until: start.addingTimeInterval(11 * 3600))
                    }
                    Spacer()
                    Text("Outside a schedule, your slider limit applies.").font(.caption).foregroundStyle(.secondary)
                }
            }
    }

    @ViewBuilder private var quitSection: some View {
            Section("When Charge Keeper quits") {
                Picker("When Charge Keeper quits", selection: Binding(get: { s.keepOnQuit }, set: { v in change { $0.keepOnQuit = v } })) {
                    Text("Charging goes back to normal").tag(false)
                    Text("Keep my limit").tag(true)
                }.pickerStyle(.radioGroup).labelsHidden()
                Text("Keep my limit works for limits of \(macFloor)% and up: the Mac holds those by itself. Limits under \(macFloor)% always need Charge Keeper running.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
    }

    @ViewBuilder private var careSection: some View {
            Section("Battery care") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calibration cycle")
                        Text("Full charge, run down to \(calibFloor)%, full again. Keeps the battery reading honest. Last run: \(s.calibratedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "never").")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Start Calibration") { startCalibration() }.disabled(!canCalibrate)
                }
                Picker(selection: Binding(get: { s.led }, set: { v in change { $0.led = v } })) {
                    Text("Normal").tag(LedMode.normal)
                    Text("Off while held").tag(LedMode.offWhileHeld)
                    Text("Always off").tag(LedMode.off)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MagSafe light")
                        Text("Off while held: dark while the battery waits at the limit.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
    }

    @ViewBuilder private var linksSection: some View {
            Section("Shortcuts and links") {
                Text("These links work in the Shortcuts app (its Open URLs action), in scripts or as a bookmark. Siri runs a shortcut by its name.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(linkExamples, id: \.self) { l in
                    Text(l).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
    }
}

enum RepeatKind: Hashable { case once, everyDay, weekdays, chosen }
func repeatKind(_ d: Set<Int>) -> RepeatKind { d.isEmpty ? .once : d == everyDay ? .everyDay : d == weekdays ? .weekdays : .chosen }

struct ScheduleEditor: View {
    @State var draft: Schedule
    let isNew: Bool
    let save: (Schedule) -> Void, delete: (UUID) -> Void, cancel: () -> Void
    @State private var kind: RepeatKind
    init(draft: Schedule, isNew: Bool, save: @escaping (Schedule) -> Void, delete: @escaping (UUID) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: draft); _kind = State(initialValue: repeatKind(draft.days))
        self.isNew = isNew; self.save = save; self.delete = delete; self.cancel = cancel
    }
    var body: some View {
        let parts: DatePickerComponents = kind == .once ? [.date, .hourAndMinute] : .hourAndMinute
        Form {
            Section {
            TextField("Name", text: $draft.name, prompt: Text("Trip"))
            Picker("Charge up to", selection: $draft.limit) { ForEach(Array(stride(from: limitRange.lowerBound, through: limitRange.upperBound, by: 5)), id: \.self) { Text(limitText($0)).tag($0) } }
            Picker("Repeat", selection: $kind) {
                Text("Once").tag(RepeatKind.once); Text("Every day").tag(RepeatKind.everyDay)
                Text("Weekdays").tag(RepeatKind.weekdays); Text("Chosen days").tag(RepeatKind.chosen)
            }
            .onChange(of: kind) { _, k in
                switch k {
                case .once: draft.days = []
                case .everyDay: draft.days = everyDay
                case .weekdays: draft.days = weekdays
                case .chosen: if draft.days.isEmpty || draft.days == everyDay { draft.days = weekdays }
                }
            }
            if kind == .chosen {
                HStack {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[d - 1], isOn: Binding(get: { draft.days.contains(d) }, set: { on in if on { draft.days.insert(d) } else if draft.days.count > 1 { draft.days.remove(d) } }))
                            .toggleStyle(.button).accessibilityLabel(Calendar.current.weekdaySymbols[d - 1])
                    }
                }
            }
            DatePicker("From", selection: $draft.from, displayedComponents: parts)
            DatePicker("Until", selection: $draft.until, displayedComponents: parts)
            Text(kind == .once ? "A Once schedule turns itself off when it ends." : "An end time before the start time runs past midnight.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if !isNew { Button("Delete", role: .destructive) { delete(draft.id) } }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var d = draft
                    if d.name.trimmingCharacters(in: .whitespaces).isEmpty { d.name = "Schedule" }
                    save(d)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(kind == .once && draft.until <= draft.from)
            }
            } header: { Text(isNew ? "New Schedule" : "Edit Schedule").font(.headline) }
        }
        .formStyle(.grouped).frame(width: 360).frame(minHeight: 308)
    }
}
