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
    var cut = false  // under 80: the charger's power is switched off, the Mac runs on its battery
    var cutNote: CutNote? = nil  // under 80, but the charger cannot be switched: the Mac's own 80 holds instead
    var heatOn = false, sailing = false
    var bottom = 75  // the sailing range's bottom ("Charge again below")
    var tempF: Double? = nil
    var paused = false  // heat pause in effect: charging stopped because the battery is warm
    var resting = false  // the top was reached, waiting for the level to come down to the bottom
}

enum CutNote: Equatable { case noHelper, aldente, otherApp, lidClosed }

// The level Charge Keeper really holds: under 80 without the charger switch, the Mac's own limit stops at 80.
func holdLevel(_ s: Snapshot) -> Int { s.cutNote == nil ? s.limit : max(s.limit, macFloor) }

// The panels that show the Mac's own limit instead of Charge Keeper's slider.
func showsChoice(_ m: Mode) -> Bool { m == .foreign || m == .steppedAside }
// Charge Keeper has let the Mac's limit be (Quit changes nothing then).
func notHolding(_ m: Mode) -> Bool { showsChoice(m) || m == .macLimit }

let limitRange = 50...100  // the approved mockup's slider; 80 and up is the Mac's own limit, under 80 the charger switch (Charger.swift)

func clampLimit(_ v: Int) -> Int { min(limitRange.upperBound, max(limitRange.lowerBound, v / 5 * 5)) }
// The sailing range's bottom: at least 5 under the top; the slider always spans at least one step (40...45 under a top of 50).
func bottomRange(_ limit: Int) -> ClosedRange<Int> { min(limitRange.lowerBound, limit - 2 * cutBand)...(limit - cutBand) }
func clampBottom(_ v: Int, limit: Int) -> Int { let r = bottomRange(limit); return min(r.upperBound, max(r.lowerBound, v / 5 * 5)) }
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
        if s.paused { return "Paused, battery warm" }
        if s.mode == .holding && s.sailing && s.resting && s.level != s.limit { return "Resting down to \(s.bottom)%" }
        if s.cut { return s.level > s.limit ? "Coming down to \(s.limit)%" : "Holding at \(s.limit)%" }
        if !s.plugged { return "On battery" }
        if s.mode == .fullOnce { return "Charging to full, once" }
        let h = holdLevel(s)
        return s.charging && s.level < h ? "Charging to \(h)%" : "Holding at \(h)%"
    }
}

// Actually charging (same test as the status line): this is what drives the green movement.
func isCharging(_ s: Snapshot) -> Bool {
    s.plugged && s.charging && !s.cut && (s.mode == .fullOnce || (s.mode == .holding && s.level < holdLevel(s)))
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
    // work queue only: John chose the Mac's own limit
    private var useMac = UserDefaults.standard.bool(forKey: "useMacLimit") { didSet { UserDefaults.standard.set(useMac, forKey: "useMacLimit") } }
    // work queue only: someone else changed the limit while we held; wait for John's choice, also after a restart
    private var aside = UserDefaults.standard.bool(forKey: "steppedAside") { didSet { UserDefaults.standard.set(aside, forKey: "steppedAside") } }
    private var adopt = false  // work queue only: one step may take over a limit that is already on
    // work queue only. From sleep until the first good reading after wake, a changed limit is set back (sleep may reset it), not
    // counted as someone else's. shortcut: a change made in the last 30 s before sleep is set back too; it cannot be told apart.
    // A sleep without a wake would leave it on until the next wake; fine, as that is the old behaviour (set back), never a lost limit.
    private var reassert = false
    private var woke = false
    // work queue only: the two switches of mockup v2, both off by default, and the sailing range's bottom
    private var heatOn = UserDefaults.standard.bool(forKey: "heatPause") { didSet { UserDefaults.standard.set(heatOn, forKey: "heatPause") } }
    private var sailOn = UserDefaults.standard.bool(forKey: "sailing") { didSet { UserDefaults.standard.set(sailOn, forKey: "sailing") } }
    private var bottom: Int { didSet { UserDefaults.standard.set(bottom, forKey: "sailBottom") } }
    private var pausedAt: Int?  // work queue only: see heatStep
    private var resting = false  // work queue only: see nextResting
    private let charger = ChargerClient(path: helperSocket)
    private var cutNow = false { didSet { napGuard() } }  // work queue only: the helper's last answer
    private var activity: NSObjectProtocol?  // while cut: keeps App Nap from stretching the 30 s check-in past the helper's 150 s
    private func napGuard() {
        if cutNow, activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Holding the charger off") }
        if !cutNow, let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "limit")
        limit = saved == 0 ? 80 : clampLimit(saved)
        let b = UserDefaults.standard.integer(forKey: "sailBottom")
        bottom = clampBottom(b == 0 ? limit - cutBand : b, limit: limit)
        limiter = MCL().map(Limiter.init)
        let nc = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.screensAsleep = asleep; self?.refreshAnimation() }
        }
        nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshAnimation() }
        if let l = limiter { installExitSafety(l) }
        registerLoginItemOnce()
        work.async { self.step() }  // the first step also cleans up a limit left by a crash or power cut (see Limiter.apply)
        RunLoop.main.add(Timer(timeInterval: 30, repeats: true) { _ in self.work.async { self.step() } }, forMode: .common)  // .common: keeps ticking during a slider drag
        // AlDente started: step at once, so a cut of ours is given back before AlDente makes its own.
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { _ in if aldenteRunning() { self.work.async { self.step() } } }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in self.work.async { self.reassert = true; self.woke = false } }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            // Sleep may have undone the limit; step() reads it and sets it back. The Mac's charge service can be slow to answer
            // right after wake, so ask again a little later; `reassert` lasts until a step actually reads it.
            self.work.async { self.woke = true }
            for delay in wakeChecks { self.work.asyncAfter(deadline: .now() + delay) { self.step() } }
        }
    }

    // Work queue: read the battery, work out what is wanted (limit, sailing range, heat pause), bring the Mac in line, publish.
    private func step() {
        let b = battery()
        if let lv = b.current {  // an unreadable level changes neither state
            pausedAt = heatStep(on: heatOn, tempF: b.tempF, level: lv, pausedAt: pausedAt)
            resting = nextResting(level: lv, top: limit, bottom: restBottom(limit: limit, sailing: sailOn, bottom: bottom), resting: resting)
        }
        let level = b.current ?? 0
        let p = plan(level: level, limit: limit, bottom: restBottom(limit: limit, sailing: sailOn, bottom: bottom), resting: resting, fullOnce: fullOnce, pausedAt: pausedAt)
        var mode = Mode.unsupported
        var mac: LimitState? = nil
        if let l = limiter {
            if fullOnce && (b.current ?? 0) >= 100 { fullOnce = false }  // the one-off ends by itself
            if useMac {
                // Normally a no-op (the choice is offered only while we hold nothing); covers a tick that took over just before the click.
                mode = l.release() ? .macLimit : .failed("Could not put charging back to normal")
            } else if aside {
                mode = .steppedAside
            } else if fullOnce && p.mac == nil {
                mode = l.release() ? .fullOnce : .failed("Could not put charging back to normal")
            } else {
                let r = l.apply(p.mac ?? 100, adopt: adopt, reassert: reassert)  // under 80 the Mac's 80 is the backstop
                switch r {
                case .ok: mode = fullOnce ? .fullOnce : .holding
                case .foreign: mode = .foreign
                case .changed: aside = true; mode = .steppedAside
                case .unsupported: mode = .unsupported
                case .failed(let why): mode = .failed(why)
                }
                if case .failed = r {} else {
                    adopt = false  // kept on a failure, so John's "Use Charge Keeper" is tried again next tick
                    if woke { reassert = false; woke = false }
                }
            }
            if notHolding(mode) { mac = l.current() }
        }
        let active = mode == .holding || mode == .fullOnce
        let want = active && b.current != nil && p.cut  // an unreadable level never switches the charger off
        let need = want || mode == .holding && (limit < macFloor || sailOn && bottom < macFloor)
        let note = steerCharger(need: need, want: want)
        let paused = active && pausedAt != nil && level > heatFloor && (level >= macFloor || cutNow)  // under 80 only a real cut pauses
        let s = Snapshot(level: level, plugged: b.external ?? false, charging: b.charging ?? false, limit: limit, mode: mode, mac: mac, cut: cutNow, cutNote: note,
                         heatOn: heatOn, sailing: sailOn, bottom: bottom, tempF: b.tempF, paused: paused, resting: resting)
        DispatchQueue.main.async {
            self.snap = s
            let before = self.anim
            self.refreshAnimation()
            if self.anim == before { self.onIcon() }  // a changed anim has already redrawn the icon (its didSet)
        }
    }

    // Work queue. need: the settings may switch the charger now (under 80, the range's bottom under 80, or a heat pause
    // under 80); each step then asks the helper (which also tells it the app is alive) for power off (want) or on.
    // Otherwise only a cut of ours is given back. AlDente running or the lid closed: Charge Keeper does not switch the charger.
    private func steerCharger(need: Bool, want: Bool) -> CutNote? {
        let aldente = need && aldenteRunning()
        guard need || cutNow else { return nil }
        let lid = need && lidClosed()  // cutting power can put a Mac with an outside screen to sleep
        let w = want && !aldente && !lid
        let r = charger.send(w)
        cutNow = r == replyCut
        if !need || !w && r == replyOn { charger.disconnect() }  // nothing of ours is off: no need to keep the line open
        if aldente { return .aldente }
        guard need else { return nil }
        if r == replyBusy { return .otherApp }
        if r != replyCut && r != replyOn { return .noHelper }
        return lid ? .lidClosed : nil
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
    func setLimit(_ v: Int) {
        work.async {
            self.limit = clampLimit(v); UserDefaults.standard.set(self.limit, forKey: "limit")
            self.bottom = clampBottom(self.bottom, limit: self.limit)  // moving the top down pushes the bottom down too
            self.step()
        }
    }
    func setBottom(_ v: Int) { work.async { self.bottom = clampBottom(v, limit: self.limit); self.step() } }
    func setHeat(_ on: Bool) { work.async { self.heatOn = on; self.step() } }  // off ends a pause straight away
    func setSailing(_ on: Bool) { work.async { self.sailOn = on; self.step() } }
    func chargeToFullOnce() { work.async { self.fullOnce = true; self.step() } }
    func backToLimit() { work.async { self.fullOnce = false; self.step() } }
    // Panel 4's choice. Charge Keeper: take over the limit that is on now. The Mac's own: Charge Keeper only shows the level, also after a restart.
    func choose(macLimit: Bool) {
        work.async {
            self.useMac = macLimit
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
        Panel(s: keeper.snap, bar: keeper.bar, act: PanelActions(setLimit: keeper.setLimit, setBottom: keeper.setBottom, heat: keeper.setHeat, sailing: keeper.setSailing,
                                                          full: keeper.chargeToFullOnce, back: keeper.backToLimit, choose: keeper.choose, quit: keeper.quit))
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
}

struct Panel: View {
    let s: Snapshot
    var bar = 0.0  // how much of the lighter "still to charge" stretch is drawn, 0...1
    let act: PanelActions
    @State private var draft: Double
    @State private var draftBottom: Double
    init(s: Snapshot, bar: Double = 0, act: PanelActions = PanelActions()) {
        self.s = s; self.bar = bar; self.act = act
        _draft = State(initialValue: Double(s.limit)); _draftBottom = State(initialValue: Double(s.bottom))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(s.level)%").font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Spacer()
                Text(statusText(s)).foregroundStyle(.secondary)
            }
            if !showsChoice(s.mode) { LevelBar(level: s.level, marker: s.mode == .holding ? s.limit : s.mode == .macLimit && s.mac?.enabled == true ? s.mac?.limit : nil,
                                               low: s.mode == .holding && s.sailing ? s.bottom : nil, stretch: isCharging(s) ? bar : 0) }
            if s.paused, let f = s.tempF {
                Note(Text("Charging is paused because the battery is \(degrees(f)).").bold().foregroundColor(.orange)
                    + Text(" It starts again by itself once the battery cools to \(degrees(heatResumeF)). ")
                    + Text(s.cut ? "Your Mac runs on its battery meanwhile." : "Your Mac keeps running on the charger meanwhile."))
            }
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
                if let n = s.cutNote { Note(cutNoteText(n)) }
                switches
            case .holding, .starting:
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Stop charging at").bold(); Spacer(); Text("\(Int(draft))%").bold() }
                    Slider(value: $draft, in: Double(limitRange.lowerBound)...Double(limitRange.upperBound), step: 5) { editing in
                        if !editing { act.setLimit(Int(draft)) }  // applied on release, not on every tick
                    }
                    HStack { Text("\(limitRange.lowerBound)%"); Spacer(); Text("\(limitRange.upperBound)%") }.font(.caption).foregroundStyle(.secondary)
                }
                if s.sailing {
                    let r = bottomRange(s.limit)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Charge again below").bold(); Spacer(); Text("\(Int(draftBottom))%").bold() }
                        Slider(value: $draftBottom, in: Double(r.lowerBound)...Double(r.upperBound), step: 5) { editing in
                            if !editing { act.setBottom(Int(draftBottom)) }
                        }
                        HStack { Text("\(r.lowerBound)%"); Spacer(); Text("\(r.upperBound)%") }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let n = s.cutNote { Note(cutNoteText(n)) }
                Button { act.full() } label: { Text("Charge to full once").frame(maxWidth: .infinity) }
                switches
            }
            Divider()
            Button(notHolding(s.mode) ? "Quit" : "Quit (charging turns back on)") { act.quit() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: notHolding(s.mode) ? 300 : 272)
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

func cutNoteText(_ n: CutNote) -> Text {
    let (head, rest): (String, String) = switch n {
    case .noHelper: ("Below 80% needs the charger helper.", " It is not installed or not answering, so Charge Keeper holds at 80% for now.")
    case .aldente: ("AlDente is running.", " Charge Keeper does not switch the charger while it runs, so it holds at 80% for now.")
    case .otherApp: ("Another app has switched the charger off.", " Charge Keeper leaves it alone and holds at 80% for now.")
    case .lidClosed: ("The lid is closed.", " Switching the charger off could put the Mac to sleep, so Charge Keeper holds at 80% until it opens.")
    }
    return Text(head).bold().foregroundColor(.orange) + Text(rest)
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
