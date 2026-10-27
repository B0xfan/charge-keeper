// The menu-bar app, following the approved mockup v1 (panels 1 to 4; panel 5 is dropped: no password is needed).
// Panel 4's choice is also shown when someone else changes the limit while Charge Keeper holds (it steps aside instead of setting it back).
import SwiftUI
import AppKit
import ServiceManagement

// foreign: the Mac's limit was already on; steppedAside: it was changed while we held; macLimit: John chose the Mac's own limit.
enum Mode: Equatable { case starting, holding, fullOnce, foreign, steppedAside, macLimit, unsupported, failed(String) }

struct Snapshot: Equatable {
    var level = 0
    var plugged = false
    var charging = false
    var limit = 80
    var mode = Mode.starting
    var mac: LimitState? = nil  // the Mac's own setting, read only while Charge Keeper is not holding
}

// The panels that show the Mac's own limit instead of Charge Keeper's slider.
func showsChoice(_ m: Mode) -> Bool { m == .foreign || m == .steppedAside }

let limitRange = 50...100  // the approved mockup's slider; macOS accepted 89 in Phase 1, whether it holds under 80 is for the app tests to show

func clampLimit(_ v: Int) -> Int { min(limitRange.upperBound, max(limitRange.lowerBound, v / 5 * 5)) }

func statusText(_ s: Snapshot) -> String {
    switch s.mode {
    case .starting: return "Starting"
    case .unsupported: return "This Mac has no charge limit"
    case .foreign: return "Not holding yet"
    case .steppedAside: return "Stepped aside"
    case .macLimit: return s.mac.map { $0.enabled ? "Mac's limit: \($0.limit)%" : "No limit on" } ?? "Mac's limit"
    case .failed: return "Could not set the limit"
    case .holding, .fullOnce:
        if !s.plugged { return "On battery" }
        if s.mode == .fullOnce { return "Charging to full, once" }
        return s.charging && s.level < s.limit ? "Charging to \(s.limit)%" : "Holding at \(s.limit)%"
    }
}

// Actually charging (same test as the status line): this is what drives the green movement.
func isCharging(_ s: Snapshot) -> Bool {
    s.plugged && s.charging && (s.mode == .fullOnce || (s.mode == .holding && s.level < s.limit))
}

// The animation is one number, 0...1 (see sweepAmount): the icon's green and the panel bar's stretch both follow it.
let stillSweep = 0.5  // Reduce Motion: a still picture of "charging"
func iconFill(_ sweep: Double) -> Double { 0.07 + 0.93 * sweep }  // the icon starts as a sliver, never empty

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
    // The icon is set straight on the menu-bar button (onIcon); only the open panel is a SwiftUI view, so `bar` is published only while it is open.
    private(set) var anim = 0.0 { didSet { if panelOpen { bar = anim }; onIcon() } }
    @Published private(set) var bar = 0.0
    var onIcon: () -> Void = {}
    private var panelOpen = false
    private var animTimer: Timer?  // exists only while the Mac is charging, Reduce Motion is off and a screen is awake
    private var screensAsleep = false
    private let limiter: Limiter?
    private let work = DispatchQueue(label: "keeper.work")  // every Mac-limit call happens here, never on the screen thread
    private var limit: Int  // work queue only
    private var fullOnce = false  // work queue only
    private var useMac = UserDefaults.standard.bool(forKey: "useMacLimit")  // work queue only: John chose the Mac's own limit
    private var aside = false  // work queue only: someone else changed the limit while we held; wait for John's choice
    private var adopt = false  // work queue only: one step may take over a limit that is already on
    private var reassertUntil = Date.distantPast  // work queue only: from sleep until shortly after wake

    init() {
        let saved = UserDefaults.standard.integer(forKey: "limit")
        limit = saved == 0 ? 80 : clampLimit(saved)
        limiter = MCL().map(Limiter.init)
        let nc = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.screensAsleep = asleep; self?.refreshAnimation() }
        }
        nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshAnimation() }
        if let l = limiter { installExitSafety(l) }
        registerLoginItemOnce()
        work.async { self.step() }  // the first step also cleans up a limit left by a crash or power cut (see Limiter.apply)
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.work.async { self.step() } }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in self.work.async { self.reassertUntil = .distantFuture } }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            // Sleep may have undone the limit; step() reads it and sets it back (not counted as someone else's change until
            // a little after wake). The Mac's charge service can be slow to answer right after wake, so ask again a little later.
            self.work.async { self.reassertUntil = Date() + (wakeChecks.last ?? 0) + 5 }
            for delay in wakeChecks { self.work.asyncAfter(deadline: .now() + delay) { self.step() } }
        }
    }

    // Work queue: read the battery, bring the Mac's limit in line with what is wanted, publish.
    private func step() {
        let b = battery()
        var mode = Mode.unsupported
        var mac: LimitState? = nil
        if let l = limiter {
            if fullOnce && (b.current ?? 0) >= 100 { fullOnce = false }  // the one-off ends by itself
            if useMac {
                // Normally a no-op (the choice is offered only while we hold nothing); covers a tick that took over just before the click.
                mode = l.release() ? .macLimit : .failed("Could not put charging back to normal")
            } else if aside {
                mode = .steppedAside
            } else if fullOnce {
                mode = l.release() ? .fullOnce : .failed("Could not put charging back to normal")
            } else {
                switch l.apply(limit, adopt: adopt, reassert: Date() < reassertUntil) {
                case .ok: mode = .holding
                case .foreign: mode = .foreign
                case .changed: aside = true; mode = .steppedAside
                case .unsupported: mode = .unsupported
                case .failed(let why): mode = .failed(why)
                }
                adopt = false
            }
            if showsChoice(mode) || mode == .macLimit { mac = l.current() }
        }
        let s = Snapshot(level: b.current ?? 0, plugged: b.external ?? false, charging: b.charging ?? false, limit: limit, mode: mode, mac: mac)
        DispatchQueue.main.async {
            self.snap = s
            let before = self.anim
            self.refreshAnimation()
            if self.anim == before { self.onIcon() }  // a changed anim has already redrawn the icon (its didSet)
        }
    }

    // Main thread. The timer runs only while charging with a screen awake; any other state stops it and shows today's plain icon.
    private func refreshAnimation() {
        let charging = isCharging(snap)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if charging && !reduced && !screensAsleep {
            guard animTimer == nil else { return }
            let t = Timer(timeInterval: 1 / sweepFPS, repeats: true) { [weak self] _ in
                guard let self else { return }
                let f = sweepAmount(Date.timeIntervalSinceReferenceDate)
                if f != self.anim { self.anim = f }  // the rest at the end of each round publishes nothing
            }
            t.tolerance = 0.1  // no need for exact ticks at a few per second; lets macOS batch wake-ups
            RunLoop.main.add(t, forMode: .common)  // .common: keeps moving while the slider is dragged
            animTimer = t
        } else {
            animTimer?.invalidate(); animTimer = nil
            let still = charging ? stillSweep : 0  // charging with the screens asleep keeps the last frame
            if !charging || reduced, anim != still { anim = still }
        }
    }

    func panel(open: Bool) { panelOpen = open; if open { bar = anim } }
    func setLimit(_ v: Int) { work.async { self.limit = clampLimit(v); UserDefaults.standard.set(self.limit, forKey: "limit"); self.step() } }
    func chargeToFullOnce() { work.async { self.fullOnce = true; self.step() } }
    func backToLimit() { work.async { self.fullOnce = false; self.step() } }
    // Panel 4's choice. Charge Keeper: take over the limit that is on now. The Mac's own: Charge Keeper only shows the level, also after a restart.
    func choose(macLimit: Bool) {
        work.async {
            self.useMac = macLimit; UserDefaults.standard.set(macLimit, forKey: "useMacLimit")
            self.aside = false; self.adopt = !macLimit; self.step()
        }
    }
    func quit() { NSApplication.shared.terminate(nil) }  // ends in exit(), whose handler puts charging back first
}

let wakeChecks: [TimeInterval] = [0, 5, 20]  // seconds after wake

// The menu-bar item is a plain AppKit status item whose picture is swapped directly (a SwiftUI menu-bar item is copied
// by macOS and re-run on every picture change, which cost about 28% CPU while charging). The panel is the same SwiftUI view in a popover.
final class StatusController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var keeper: Keeper!
    private var item: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ n: Notification) {
        keeper = Keeper()
        keeper.onIcon = { [weak self] in self?.updateIcon() }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        // Act on mouse-down, as macOS's own menu-bar items do. On mouse-up (the default) a click held over 0.3 s would pass the
        // reopen guard below: the open panel closes itself at mouse-down, the action would come only at mouse-up.
        item.button?.sendAction(on: [.leftMouseDown])
        item.button?.setAccessibilityLabel("Charge Keeper")
        let host = NSHostingController(rootView: PanelHost(keeper: keeper))
        host.sizingOptions = .preferredContentSize  // the panel is wider in the two-limits note
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        updateIcon()
    }

    // Charging: the coloured picture, toned for the bar's real look at draw time (it can differ from the app's). Otherwise the template icon.
    private func updateIcon() {
        let s = keeper.snap
        item.button?.image = isCharging(s) ? liveChargingIcon(level: s.level, fill: iconFill(keeper.anim)) : makeBattery(level: s.level)
    }

    private var closedAt = Date.distantPast
    private let reopenGuard = 0.3  // seconds: a click this soon after a close is the same click
    // A click on the icon while the panel is open first closes it (click-away, at mouse-down), then arrives here within the same event: that click must not reopen it.
    @objc private func toggle() { if popover.isShown { popover.performClose(nil) } else if Date().timeIntervalSince(closedAt) > reopenGuard { show() } }

    private func show() {
        guard let b = item.button else { return }
        keeper.panel(open: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)  // an accessory app is not active by default, so the slider and the click-away would not work
    }

    // will, not did: did comes after the close animation. Only a fresh mouse-down on our own button counts (currentEvent can be a stale one after Cmd-Tab): Esc or a click elsewhere must not block a real click soon after.
    func popoverWillClose(_ notification: Notification) {
        if let e = NSApp.currentEvent, e.type == .leftMouseDown, e.window === item.button?.window, ProcessInfo.processInfo.systemUptime - e.timestamp < reopenGuard { closedAt = Date() }
    }
    func popoverDidClose(_ notification: Notification) { keeper.panel(open: false) }
}

func runApp() -> Never {
    let app = NSApplication.shared
    let controller = StatusController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { app.run() }
    exit(0)
}

struct PanelHost: View {
    @ObservedObject var keeper: Keeper
    var body: some View {
        Panel(s: keeper.snap, bar: keeper.bar, act: PanelActions(setLimit: keeper.setLimit, full: keeper.chargeToFullOnce, back: keeper.backToLimit, choose: keeper.choose, quit: keeper.quit))
    }
}

struct PanelActions {
    var setLimit: (Int) -> Void = { _ in }
    var full: () -> Void = {}
    var back: () -> Void = {}
    var choose: (Bool) -> Void = { _ in }  // true: the Mac's own limit
    var quit: () -> Void = {}
}

struct Panel: View {
    let s: Snapshot
    var bar = 0.0  // how much of the lighter "still to charge" stretch is drawn, 0...1
    let act: PanelActions
    @State private var draft: Double
    init(s: Snapshot, bar: Double = 0, act: PanelActions = PanelActions()) { self.s = s; self.bar = bar; self.act = act; _draft = State(initialValue: Double(s.limit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(s.level)%").font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Spacer()
                Text(statusText(s)).foregroundStyle(.secondary)
            }
            if !showsChoice(s.mode) { LevelBar(level: s.level, marker: s.mode == .holding ? s.limit : s.mode == .macLimit && s.mac?.enabled == true ? s.mac?.limit : nil, stretch: isCharging(s) ? bar : 0) }
            switch s.mode {
            case .foreign, .steppedAside:
                Note((s.mode == .foreign ? Text("Your Mac has its own charge limit turned on.")
                      : Text("The charge limit was changed outside Charge Keeper\(s.mac.map { $0.enabled ? " (now \($0.limit)%)" : " (now off)" } ?? "").")).bold().foregroundColor(.orange)
                    + Text(s.mode == .foreign ? " Two limits can get in each other's way, so Charge Keeper is waiting. Pick the one you want."
                           : " Charge Keeper stepped aside instead of changing it back. Pick the one you want."))
                Choice(limit: s.limit, choose: act.choose)
            case .macLimit:
                Note(Text(s.mac?.enabled == false ? "You chose the Mac's own limit, and it is off now." : "The Mac's own limit is in charge.").bold().foregroundColor(.orange)
                    + Text(" Charge Keeper only shows the level."))
                Button { act.choose(false) } label: { Text("Use Charge Keeper instead").frame(maxWidth: .infinity) }
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
            Button(s.mode == .holding || s.mode == .fullOnce ? "Quit (charging turns back on)" : "Quit") { act.quit() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: showsChoice(s.mode) || s.mode == .macLimit ? 300 : 272)
        .onAppear { draft = Double(s.limit) }
        .onChange(of: s.limit) { _, new in draft = Double(new) }
    }
}

// The mockup's battery bar: track, green fill, and a thin mark at the limit.
struct LevelBar: View {
    let level: Int
    let marker: Int?
    var stretch = 0.0
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.35))
                    Rectangle().fill(Color.green).frame(width: w * CGFloat(min(100, max(0, level))) / 100)
                    if case let end = marker ?? 100, end > level, stretch > 0 {  // no marker (charge to full once): sweeps to 100
                        Rectangle().fill(Color.green.opacity(0.55)).frame(width: w * CGFloat(end - level) / 100 * stretch).offset(x: w * CGFloat(level) / 100)
                    }
                }.clipShape(Capsule())
                if let m = marker { Rectangle().fill(Color.primary).frame(width: 2, height: 14).offset(x: w * CGFloat(m) / 100 - 1) }
            }
        }.frame(height: 10)
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
            Button { choose(mac) } label: { Text("Use this choice").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
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

struct Note: View {
    let text: Text
    init(_ text: Text) { self.text = text }
    var body: some View {
        text.fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
