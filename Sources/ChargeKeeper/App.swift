// The menu-bar app, following the approved mockup v1 (panels 1 to 3; panel 4 is the note without its choice buttons,
// panel 5 is dropped: no password is needed).
import SwiftUI
import AppKit
import ServiceManagement

enum Mode: Equatable { case starting, holding, fullOnce, foreign, unsupported, failed(String) }

struct Snapshot: Equatable {
    var level = 0
    var plugged = false
    var charging = false
    var limit = 80
    var mode = Mode.starting
}

let limitRange = 50...100  // the approved mockup's slider; macOS accepted 89 in Phase 1, whether it holds under 80 is for the app tests to show

func clampLimit(_ v: Int) -> Int { min(limitRange.upperBound, max(limitRange.lowerBound, v / 5 * 5)) }

func statusText(_ s: Snapshot) -> String {
    switch s.mode {
    case .starting: return "Starting"
    case .unsupported: return "This Mac has no charge limit"
    case .foreign: return "Not holding yet"
    case .failed: return "Could not set the limit"
    case .holding, .fullOnce:
        if !s.plugged { return "On battery" }
        if s.mode == .fullOnce { return "Charging to full, once" }
        return s.charging && s.level < s.limit ? "Charging to \(s.limit)%" : "Holding at \(s.limit)%"
    }
}

// Start with the Mac, once, and only for the copy in /Applications (a build folder copy must not become a login item).
// If John switches it off in System Settings it stays off: the question is asked a single time.
func shouldRegisterLoginItem(path: String, asked: Bool) -> Bool { !asked && path.hasPrefix("/Applications/") }

func registerLoginItemOnce() {
    let d = UserDefaults.standard
    guard shouldRegisterLoginItem(path: Bundle.main.bundlePath, asked: d.bool(forKey: "loginItemAsked")) else { return }
    do { try SMAppService.mainApp.register(); d.set(true, forKey: "loginItemAsked") } catch {}  // on failure, tried again next launch
}

final class Keeper: ObservableObject {
    @Published private(set) var snap = Snapshot()
    private let limiter: Limiter?
    private let work = DispatchQueue(label: "keeper.work")  // every Mac-limit call happens here, never on the screen thread
    private var limit: Int  // work queue only
    private var fullOnce = false  // work queue only

    init() {
        let saved = UserDefaults.standard.integer(forKey: "limit")
        limit = saved == 0 ? 80 : clampLimit(saved)
        limiter = MCL().map(Limiter.init)
        if let l = limiter { installExitSafety(l) }
        registerLoginItemOnce()
        work.async { self.step() }  // the first step also cleans up a limit left by a crash or power cut (see Limiter.apply)
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.work.async { self.step() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            // Sleep may have undone the limit; step() reads it and re-applies. The Mac's charge service can be slow
            // to answer right after wake, so ask again a little later instead of waiting for the 30 s tick.
            for delay in wakeChecks { self.work.asyncAfter(deadline: .now() + delay) { self.step() } }
        }
    }

    // Work queue: read the battery, bring the Mac's limit in line with what is wanted, publish.
    private func step() {
        let b = battery()
        var mode = Mode.unsupported
        if let l = limiter {
            if fullOnce && (b.current ?? 0) >= 100 { fullOnce = false }  // the one-off ends by itself
            if fullOnce {
                mode = l.release() ? .fullOnce : .failed("Could not put charging back to normal")
            } else {
                switch l.apply(limit) {
                case .ok: mode = .holding
                case .foreign: mode = .foreign
                case .unsupported: mode = .unsupported
                case .failed(let why): mode = .failed(why)
                }
            }
        }
        let s = Snapshot(level: b.current ?? 0, plugged: b.external ?? false, charging: b.charging ?? false, limit: limit, mode: mode)
        DispatchQueue.main.async { self.snap = s }
    }

    func setLimit(_ v: Int) { work.async { self.limit = clampLimit(v); UserDefaults.standard.set(self.limit, forKey: "limit"); self.step() } }
    func chargeToFullOnce() { work.async { self.fullOnce = true; self.step() } }
    func backToLimit() { work.async { self.fullOnce = false; self.step() } }
    func quit() { NSApplication.shared.terminate(nil) }  // ends in exit(), whose handler puts charging back first
}

let wakeChecks: [TimeInterval] = [0, 5, 20]  // seconds after wake

struct KeeperApp: App {  // started from main.swift
    @StateObject private var keeper = Keeper()
    var body: some Scene {
        MenuBarExtra {
            Panel(s: keeper.snap, act: PanelActions(setLimit: keeper.setLimit, full: keeper.chargeToFullOnce, back: keeper.backToLimit, quit: keeper.quit))
        } label: {
            MenuBarLabel(level: keeper.snap.level)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let level: Int
    var body: some View { HStack(spacing: 4) { Image(nsImage: shieldBattery); Text("\(level)%") } }
}

struct PanelActions {
    var setLimit: (Int) -> Void = { _ in }
    var full: () -> Void = {}
    var back: () -> Void = {}
    var quit: () -> Void = {}
}

struct Panel: View {
    let s: Snapshot
    let act: PanelActions
    @State private var draft: Double
    init(s: Snapshot, act: PanelActions = PanelActions()) { self.s = s; self.act = act; _draft = State(initialValue: Double(s.limit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(s.level)%").font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Spacer()
                Text(statusText(s)).foregroundStyle(.secondary)
            }
            if s.mode != .foreign { LevelBar(level: s.level, marker: s.mode == .holding ? s.limit : nil) }
            switch s.mode {
            case .foreign:
                Note(Text("Your Mac has its own charge limit turned on.").bold().foregroundColor(.orange)
                    + Text(" Two limits can get in each other's way, so Charge Keeper is waiting. Turn off the Mac's limit in Battery settings and Charge Keeper takes over by itself."))
            case .unsupported:
                Note(Text("This Mac has no built-in charge limit.").bold().foregroundColor(.orange) + Text(" Charge Keeper cannot hold a level here."))
            case .failed(let why):
                Note(Text("Charge Keeper could not set the limit.").bold().foregroundColor(.orange) + Text(" \(why)"))
            case .fullOnce:
                Note(Text("Your limit is paused. When the battery reaches 100%, Charge Keeper goes back to holding at ")
                    + Text("\(s.limit)%").bold().foregroundColor(.orange) + Text(" by itself."))
                Button { act.back() } label: { Text("Stop and go back to \(s.limit)%").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            case .holding, .starting:
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Stop charging at").bold(); Spacer(); Text("\(Int(draft))%").bold() }
                    Slider(value: $draft, in: Double(limitRange.lowerBound)...Double(limitRange.upperBound), step: 5) { editing in
                        if !editing { act.setLimit(Int(draft)) }  // applied on release, not on every tick
                    }
                    HStack { Text("\(limitRange.lowerBound)%"); Spacer(); Text("\(limitRange.upperBound)%") }.font(.caption).foregroundStyle(.secondary)
                }
                Button { act.full() } label: { Text("Charge to full once").frame(maxWidth: .infinity) }
            }
            Divider()
            Button("Quit (charging turns back on)") { act.quit() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: s.mode == .foreign ? 300 : 272)
        .onChange(of: s.limit) { _, new in draft = Double(new) }
    }
}

// The mockup's battery bar: track, green fill, and a thin mark at the limit.
struct LevelBar: View {
    let level: Int
    let marker: Int?
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.35))
                    Rectangle().fill(Color.green).frame(width: w * CGFloat(min(100, max(0, level))) / 100)
                }.clipShape(Capsule())
                if let m = marker { Rectangle().fill(Color.primary).frame(width: 2, height: 14).offset(x: w * CGFloat(m) / 100 - 1) }
            }
        }.frame(height: 10)
    }
}

struct Note: View {
    let text: Text
    init(_ text: Text) { self.text = text }
    var body: some View {
        text.fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
