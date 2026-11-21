// The menu-bar panel (approved mockups v1 to v3) and its parts.
import SwiftUI

struct PanelHost: View {
    @ObservedObject var keeper: Keeper
    var openSettings: () -> Void = {}
    var body: some View {
        Panel(s: keeper.snap, bar: keeper.bar, act: PanelActions(setLimit: keeper.setLimit, setBottom: keeper.setBottom, heat: keeper.setHeat, sailing: keeper.setSailing,
                                                          full: keeper.chargeToFullOnce, back: keeper.backToLimit, choose: keeper.choose, quit: keeper.quit,
                                                          runDown: keeper.startRunDown, stopRunDown: keeper.stopRunDown, cancelCalibration: keeper.cancelCalibration,
                                                          skip: keeper.skipSchedule, lowPower: keeper.setLowPower, settings: openSettings,
                                                          installHelper: keeper.installHelper), helperBusy: keeper.helperBusy, helperFailed: keeper.helperFailed)
    }
}

struct PanelActions {
    var setLimit: (Int) -> Void = { _ in }
    var setBottom: (Int) -> Void = { _ in }
    var heat: (Bool) -> Void = { _ in }
    var sailing: (Bool) -> Void = { _ in }
    var full: () -> Void = {}
    var back: () -> Void = {}
    var choose: (Bool) -> Void = { _ in }  // true: the Mac's own limit
    var quit: () -> Void = {}
    var runDown: () -> Void = {}
    var stopRunDown: () -> Void = {}
    var cancelCalibration: () -> Void = {}
    var skip: () -> Void = {}
    var lowPower: (Bool) -> Void = { _ in }
    var settings: () -> Void = {}
    var installHelper: () -> Void = {}
}

struct Panel: View {
    let s: Snapshot
    var bar = 0.0  // how much of the lighter "still to charge" stretch is drawn, 0...1
    let act: PanelActions
    var helperBusy = false  // the helper install's password box is open
    var helperFailed = false
    @State private var draft: Double
    @State private var draftBottom: Double
    init(s: Snapshot, bar: Double = 0, act: PanelActions = PanelActions(), helperBusy: Bool = false, helperFailed: Bool = false) {
        self.s = s; self.bar = bar; self.act = act; self.helperBusy = helperBusy; self.helperFailed = helperFailed
        _draft = State(initialValue: Double(s.limit)); _draftBottom = State(initialValue: Double(s.bottom))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(s.level)%").font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Spacer()
                Text(statusText(s)).foregroundStyle(.secondary)
            }
            if !showsChoice(s.mode) { LevelBar(level: s.level, marker: s.calib == 2 ? calibFloor : s.calib > 0 ? nil : s.mode == .holding ? s.limit : s.mode == .macLimit && s.mac?.enabled == true ? s.mac?.limit : nil,
                                               low: s.mode == .holding && s.sailing ? s.bottom : nil, stretch: isCharging(s) ? bar : 0) }
            if s.paused, let f = s.tempF {
                Note(Text("Charging is paused because the battery is \(degrees(f)).").bold().foregroundColor(warnText)
                    + Text(" It starts again by itself once the battery cools to \(degrees(heatResumeF)). ")
                    + Text(s.cut ? "Your Mac runs on its battery meanwhile." : "Your Mac keeps running on the charger meanwhile."))
            }
            if s.calib > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(["Charge to 100%", "Run down to \(calibFloor)% on battery", "Charge to 100%, then back to \(s.scheduled?.back ?? s.limit)%"].enumerated()), id: \.offset) { i, t in
                        Text("\(i + 1). \(t)\(i + 1 == s.calib ? " (now)" : "")").fontWeight(i + 1 == s.calib ? .semibold : .regular)
                            .strikethrough(i + 1 < s.calib).foregroundStyle(i + 1 < s.calib ? .secondary : .primary)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                if let n = s.cutNote { cutNote(n) }
                Text("Keep the charger plugged in. This takes most of a day; you can use the Mac meanwhile.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { act.cancelCalibration() } label: { Text("Cancel Calibration").frame(maxWidth: .infinity) }
            } else if let t = s.runDown {
                if s.autoRun {  // mockup v4
                    Note(Text("Running down by itself to your \(t)% limit.").bold().foregroundColor(coolText)
                         + Text(" At \(t)% the Mac goes back to the charger. Unplugging or quitting also switches back."), cool: true)
                } else {
                    Note(Text("Your Mac is running on its battery although the charger is plugged in.").bold().foregroundColor(warnText)
                         + Text(" At \(t)% it switches back to the charger by itself. Quitting or unplugging also switches back."), cool: true)
                }
                if let n = s.cutNote { cutNote(n) }
                Button { act.stopRunDown() } label: { Text(s.autoRun ? "Stop This Time" : "Stop and Use the Charger").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                switches
            } else if let sc = s.scheduled, s.mode == .holding {
                Note(Text("Schedule \"\(sc.name)\":").bold().foregroundColor(warnText)
                     + Text(" \(s.limit == 100 ? "full" : "\(s.limit)%") until \(sc.until.formatted(.dateTime.weekday(.wide).hour().minute())), then back to \(sc.back)%."), cool: true)
                if let n = s.cutNote { cutNote(n) }
                Button { act.skip() } label: { Text("Skip This Time").frame(maxWidth: .infinity) }
                switches
            } else {
            switch s.mode {
            case .foreign, .steppedAside:
                Note((s.mode == .foreign ? Text("Your Mac has its own charge limit turned on.")
                      : Text("The charge limit was changed outside Charge Keeper\(s.mac.map { $0.enabled ? " (now \($0.limit)%)" : " (now off)" } ?? "").")).bold().foregroundColor(warnText)
                    + Text(s.mode == .foreign ? " Two limits can get in each other's way, so Charge Keeper is waiting. Pick the one you want."
                           : " Charge Keeper stepped aside instead of changing it back. Pick the one you want."))
                Choice(limit: s.limit, choose: act.choose)
            case .macLimit:
                Note(Text(s.mac?.enabled == false ? "You chose the Mac's own limit, and it is off now." : "The Mac's own limit is in charge.").bold().foregroundColor(warnText)
                    + Text(" Charge Keeper only shows the level."))
                Button { act.choose(false) } label: { Text("Use Charge Keeper Instead").frame(maxWidth: .infinity) }
            case .unsupported:
                Note(Text("This Mac has no built-in charge limit.").bold().foregroundColor(warnText) + Text(" Charge Keeper cannot hold a level here."))
            case .failed(let why):
                Note(Text("Charge Keeper could not set the limit.").bold().foregroundColor(warnText) + Text(" \(why)"))
            case .fullOnce:
                Note(Text("Your limit is paused. When the battery reaches 100%, Charge Keeper goes back to holding at ")
                    + Text("\(s.limit)%").bold().foregroundColor(warnText) + Text(" by itself."))
                Button { act.back() } label: { Text("Stop and Go Back to \(s.limit)%").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                if let n = s.cutNote { cutNote(n) }
                switches
            case .holding, .starting:
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Charge up to").bold(); Spacer(); Text("\(Int(draft))%").bold() }
                    Slider(value: $draft, in: Double(limitRange.lowerBound)...Double(limitRange.upperBound), step: 5) { editing in
                        if !editing { act.setLimit(Int(draft)) }  // applied on release, not on every tick
                    }.accessibilityLabel("Charge up to").accessibilityValue("\(Int(draft))%")
                    HStack { Text("\(limitRange.lowerBound)%"); Spacer(); Text("\(limitRange.upperBound)%") }.font(.caption).foregroundStyle(.secondary)
                }
                if s.sailing {
                    let r = bottomRange(s.limit)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Charge again below").bold(); Spacer(); Text("\(Int(draftBottom))%").bold() }
                        Slider(value: $draftBottom, in: Double(r.lowerBound)...Double(r.upperBound), step: 5) { editing in
                            if !editing { act.setBottom(Int(draftBottom)) }
                        }.accessibilityLabel("Charge again below").accessibilityValue("\(Int(draftBottom))%")
                        HStack { Text("\(r.lowerBound)%"); Spacer(); Text("\(r.upperBound)%") }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let n = s.cutNote { cutNote(n) }
                if s.mode == .holding && s.plugged && s.level > holdLevel(s) && !s.cut && !s.calibrating {
                    Button { act.runDown() } label: { Text("Run Down to \(s.limit)% on Battery").frame(maxWidth: .infinity) }
                }
                Button { act.full() } label: { Text("Charge to Full Once").frame(maxWidth: .infinity) }
                switches
            }
            }
            Divider()
            HStack {
                Button(notHolding(s.mode) ? "Quit" : s.keepsOnQuit ? "Quit (keeps \(s.limit)%)" : "Quit (charging turns back on)") { act.quit() }
                Spacer()
                Button("Settings…") { act.settings() }.keyboardShortcut(",")
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: notHolding(s.mode) || s.runDown != nil || s.calib > 0 ? 300 : 272)
        .onAppear { draft = Double(s.limit); draftBottom = Double(s.bottom) }
        .onChange(of: s.limit) { _, new in draft = Double(new) }
        .onChange(of: s.bottom) { _, new in draftBottom = Double(new) }
    }

    // Mockup v2: the two switches under the buttons, each with a small line that says what it does right now.
    @ViewBuilder private var switches: some View {
        Divider()
        Setting(title: "Heat pause", hint: s.heatOn ? "Pauses above \(degrees(heatPauseF)).\(s.tempF.map { " Battery now \(degrees($0))." } ?? "")" : "Stop charging while the battery is warm.",
                on: s.heatOn, set: act.heat)
        Setting(title: "Sailing range", hint: s.sailing ? "Charges up to \(s.limit)%, then waits until \(s.bottom)%." : "Let the battery drift down a little before charging again.",
                on: s.sailing, set: act.sailing)
        Setting(title: "Low Power Mode", hint: s.helperOld ? "Needs the charger helper updated." : "The Mac's own energy saver. \(s.lowPower ? "On" : "Off") now.",
                on: s.lowPower, set: act.lowPower)
        if s.helperOld && s.cutNote != .oldHelper { helperButton(update: true) }
    }

    // A warning about the helper carries the button that fixes it.
    @ViewBuilder private func cutNote(_ n: CutNote) -> some View {
        Note(cutNoteText(n))
        if n == .noHelper || n == .oldHelper { helperButton(update: n == .oldHelper) }
    }
    @ViewBuilder private func helperButton(update: Bool) -> some View {
        Button { act.installHelper() } label: { Text(helperBusy ? "Waiting for Your Password…" : update ? "Update Charger Helper…" : "Install Charger Helper…").frame(maxWidth: .infinity) }
            .disabled(helperBusy).help("Asks for your Mac password once")
        if helperFailed { Text("That did not work. Check that Charge Keeper is in Applications, then try again.").font(.caption).foregroundStyle(.secondary) }
    }
}

struct Setting: View {
    let title: String, hint: String, on: Bool
    let set: (Bool) -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: Binding(get: { on }, set: set)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

// The mockup's battery bar: track, green fill, and a thin mark at the limit.
struct LevelBar: View {
    let level: Int
    let marker: Int?
    var low: Int? = nil  // the sailing range's bottom: a thin band up to the marker and a second, lighter mark
    var stretch = 0.0
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.35))
                    if let lo = low, let m = marker, m > lo { Rectangle().fill(Color.green.opacity(0.3)).frame(width: w * CGFloat(m - lo) / 100).offset(x: w * CGFloat(lo) / 100) }
                    Rectangle().fill(Color.green).frame(width: w * CGFloat(min(100, max(0, level))) / 100)
                    if case let end = marker ?? 100, end > level, stretch > 0 {  // no marker (charge to full once): sweeps to 100
                        Rectangle().fill(Color.green.opacity(0.55)).frame(width: w * CGFloat(end - level) / 100 * CGFloat(stretch)).offset(x: w * CGFloat(level) / 100)
                    }
                }.clipShape(Capsule())
                if let m = marker { Rectangle().fill(Color.primary).frame(width: 2, height: 14).offset(x: w * CGFloat(m) / 100 - 1) }
                if let lo = low { Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 2, height: 14).offset(x: w * CGFloat(lo) / 100 - 1) }
            }
        }.frame(height: 10)
        .accessibilityElement().accessibilityLabel("Battery level")
        .accessibilityValue("\(level)%\(marker.map { ", limit \($0)%" } ?? "")")
    }
}

// Mockup v1 panel 4: two options, then one button that applies the picked one.
struct Choice: View {
    let limit: Int
    let choose: (Bool) -> Void
    @State private var mac = false
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                option(false, "Use Charge Keeper", "Charge Keeper turns off the Mac's limit and holds at \(limit)%.")
                option(true, "Use the Mac's own limit", "Charge Keeper steps aside and only shows the level.")
            }
            Button { choose(mac) } label: { Text("Apply Choice").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
        }
    }
    private func option(_ value: Bool, _ title: String, _ detail: String) -> some View {
        Button { mac = value } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: mac == value ? "record.circle.fill" : "circle").foregroundStyle(mac == value ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8).contentShape(Rectangle())
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mac == value ? .isSelected : [])
    }
}

func cutNoteText(_ n: CutNote) -> Text {
    let (head, rest): (String, String) = switch n {
    case .noHelper: ("Below \(macFloor)% needs the charger helper.", " It is not installed or not answering, so Charge Keeper holds at \(macFloor)% for now.")
    case .aldente: ("AlDente is running.", " Charge Keeper does not switch the charger while it runs, so it holds at \(macFloor)% for now.")
    case .otherApp: ("Another app has switched the charger off.", " Charge Keeper leaves it alone and holds at \(macFloor)% for now.")
    case .lidClosed: ("The lid is closed.", " Switching the charger off could put the Mac to sleep, so Charge Keeper holds at \(macFloor)% until it opens.")
    case .oldHelper: ("The charger helper is out of date.", " It needs updating once (with your Mac password) before Charge Keeper can run the battery down this far.")
    }
    return Text(head).bold().foregroundColor(warnText) + Text(rest)
}

struct Note: View {
    let text: Text
    var cool = false  // mockup v3: blue for "Charge Keeper is doing what you asked", orange for warnings
    init(_ text: Text, cool: Bool = false) { self.text = text; self.cool = cool }
    var body: some View {
        text.fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background((cool ? Color.blue.opacity(0.12) : Color.orange.opacity(0.15)), in: RoundedRectangle(cornerRadius: 8))
    }
}

// Blue headings on the blue note (mockup v4): systemBlue on pale blue is about 3:1 in light mode; this darker one about 5:1.
let coolText = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemBlue : NSColor(srgbRed: 0.04, green: 0.37, blue: 0.78, alpha: 1) })
// Orange warning headings: macOS's orange is too light on the pale orange note in light mode (about 2:1); this darker one is about 5:1.
let warnText = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemOrange : NSColor(srgbRed: 0.6, green: 0.31, blue: 0, alpha: 1) })
