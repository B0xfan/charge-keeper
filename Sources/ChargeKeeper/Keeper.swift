// The controller: owns every Mac-limit, charger and setting change on its work queue and publishes a Snapshot for the screens.
import SwiftUI
import AppKit

final class Keeper: ObservableObject {
    @Published private(set) var snap = Snapshot()
    // The icon is set straight on the menu-bar button (onIcon); only the open panel is a SwiftUI view, so `bar` is published only while it is open.
    private(set) var anim = 0.0 { didSet { if panelOpen { bar = anim }; onIcon() } }
    @Published private(set) var bar = 0.0
    var onIcon: () -> Void = {}
    private var panelOpen = false
    private var animTimer: Timer?  // exists only while the Mac is charging, Reduce Motion is off and a screen is awake
    private var screensAsleep = false
    private let limiter: ChargeLimit?
    private let floor = intelMac ? 0 : macFloor  // the lowest limit held without the charger switch: the helper's BCLM holds any on Intel
    private let work = DispatchQueue(label: "keeper.work")  // every Mac-limit call happens here, never on the screen thread
    private var limit: Int  // work queue only
    // work queue only: the user chose the Mac's own limit
    private var useMac = UserDefaults.standard.bool(forKey: "useMacLimit") { didSet { UserDefaults.standard.set(useMac, forKey: "useMacLimit") } }
    // work queue only: someone else changed the limit while we held; wait for the user's choice, also after a restart
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
    // work queue only: the state decide() carries from step to step.
    // Any end of a calibration cycle (done, cancelled or cut short) restarts the schedule's count, so a run that cannot finish is not started again at once.
    private var c = Carry() { didSet { if oldValue.calib > 0 && c.calib == 0 && settings.calibEvery > 0 { settings.calibSince = Date() } } }
    private var skipped: [UUID: Date] = [:]  // "Skip this time": the occurrence (by its end) left out
    private var ledIsDark = false
    private var helperOld = false  // once seen, nothing new is sent: an old helper reads any new byte as "power on" and would undo a cut
    private var leftOnCheck = false  // work queue only: the last run quit with "Keep my limit"; checked once, at the first step
    private var quitting = false  // work queue only
    private var wasHolding = false  // the last step held the limit (a scheduled calibration waits for that)
    private var health: BatteryHealth?  // work queue only; read once an hour and when Settings opens
    private var healthRead = Date.distantPast
    private var settings: KeeperSettings {
        didSet {
            let d = UserDefaults.standard
            d.set(try? JSONEncoder().encode(settings.schedules), forKey: "schedules")
            d.set(settings.keepOnQuit, forKey: "keepOnQuit"); d.set(settings.led.rawValue, forKey: "magsafeLight")
            d.set(settings.calibratedAt, forKey: "calibratedAt")
            d.set(settings.calibEvery, forKey: "calibEvery"); d.set(settings.calibSince, forKey: "calibSince")
            d.set(settings.autoRunDown, forKey: "autoRunDown"); d.set(try? JSONEncoder().encode(settings.look), forKey: "look")
        }
    }
    private let ledLine = ChargerClient(path: helperSocket)  // kept open while the light is dark: its closing gives the light back
    private let charger = ChargerClient(path: helperSocket)
    private var aldente = false  // work queue only: AlDente is running (a copy of the main thread's reading)
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
        let d = UserDefaults.standard
        settings = KeeperSettings(schedules: (d.data(forKey: "schedules")).flatMap { try? JSONDecoder().decode([Schedule].self, from: $0) } ?? [],
                            keepOnQuit: d.bool(forKey: "keepOnQuit"), led: LedMode(rawValue: d.integer(forKey: "magsafeLight")) ?? .normal,
                            calibratedAt: d.object(forKey: "calibratedAt") as? Date,
                            calibEvery: d.integer(forKey: "calibEvery"), calibSince: d.object(forKey: "calibSince") as? Date,
                            autoRunDown: d.bool(forKey: "autoRunDown"),
                            look: d.data(forKey: "look").flatMap { try? JSONDecoder().decode(Look.self, from: $0) } ?? Look())
        // Quit with "Keep my limit" left the Mac's limit on: take it back over instead of asking as if it were someone else's.
        leftOnCheck = d.bool(forKey: "leftOn"); d.removeObject(forKey: "leftOn")
        limiter = intelMac ? HelperLimiter() : MCL().map(Limiter.init)
        let nc = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.screensAsleep = asleep; self?.refreshAnimation() }
        }
        nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshAnimation() }
        if let l = limiter { installExitSafety(l) }
        registerLoginItemOnce()
        aldente = aldenteRunning()  // before the first step, so it never cuts while AlDente runs (nothing is on the work queue yet)
        work.async { self.step() }  // the first step also cleans up a limit left by a crash or power cut (see Limiter.apply)
        let tick = Timer(timeInterval: 30, repeats: true) { _ in self.work.async { self.step() } }
        tick.tolerance = 3  // lets macOS group this wake-up with others; far inside the helper's 150 s check-in
        RunLoop.main.add(tick, forMode: .common)  // .common: keeps ticking during a slider drag
        // The running-apps list is read here on the main thread only (Apple does not promise it off it); the work queue gets a copy.
        // AlDente started: step at once, so a cut of ours is given back before AlDente makes its own.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                let up = aldenteRunning()
                self.work.async { let started = up && !self.aldente; self.aldente = up; if started { self.step() } }
            }
        }
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
        guard !quitting else { return }  // the limit is being put back: a step now would report it as a failure
        let b = battery()
        let level = b.current ?? 0
        // Schedules: an ended once schedule turns itself off; the one running now (highest limit) replaces the slider's limit.
        let now = Date()
        if settings.schedules.contains(where: { expired($0, now: now) }) { settings.schedules = settings.schedules.map { var x = $0; if expired(x, now: now) { x.on = false }; return x } }
        skipped = skipped.filter { $0.value > now }
        let sched = activeSchedule(settings.schedules, now: now, skipped: skipped)
        let due = wasHolding && nextCalibration(months: settings.calibEvery, last: settings.calibratedAt, since: settings.calibSince).map { now >= $0 } == true
        let macCal = macChargingToFull()
        if now.timeIntervalSince(healthRead) > 3600 || now < healthRead { health = readHealth(); healthRead = now }
        let d = decide(&c, level: b.current, external: b.external, tempF: b.tempF, scheduled: sched.map { $0.0.limit }, limit: limit,
                       sailing: sailOn, bottom: bottom, heat: heatOn, calibDue: due, autoRunDown: settings.autoRunDown, holding: wasHolding,
                       macCal: macCal, floor: floor, lid: lidClosed())
        if d.calibDone { settings.calibratedAt = now }
        let top = d.top, filling = d.filling, p = d.plan
        var mode = Mode.unsupported
        var mac: LimitState? = nil
        if let l = limiter {
            // Take back over only the limit we left on: one the user has changed since then is theirs, and is asked about as usual.
            if leftOnCheck { leftOnCheck = false; if l.current() == LimitState(enabled: true, limit: limit) { adopt = true } }
            if useMac {
                // Normally a no-op (the choice is offered only while we hold nothing); covers a tick that took over just before the click.
                mode = l.release() ? .macLimit : .failed("Could not put charging back to normal")
            } else if aside {
                mode = .steppedAside
            } else if filling && p.mac == nil {
                mode = l.release() ? .fullOnce : .failed("Could not put charging back to normal")
            } else {
                let r = l.apply(p.mac ?? 100, adopt: adopt, reassert: reassert)  // under 80 the Mac's 80 is the backstop
                switch r {
                case .ok: mode = filling ? .fullOnce : .holding
                case .foreign: mode = .foreign
                case .changed: aside = true; mode = .steppedAside
                case .unsupported: mode = .unsupported
                case .failed(let why): mode = .failed(why)
                case .noHelper(let old): mode = .needsHelper; if old { helperOld = true }
                }
                if case .failed = r {} else {
                    adopt = false  // kept on a failure, so the user's "Use Charge Keeper" is tried again next tick
                    if woke { reassert = false; woke = false }
                }
            }
            if notHolding(mode) { mac = l.current() }
        }
        let active = mode == .holding || mode == .fullOnce
        wasHolding = mode == .holding
        // Both need Charge Keeper holding. A failed step keeps them (it may be a moment's hiccup; no cut is made meanwhile).
        if case .failed = mode {} else if !active { c.runDown = nil; c.calib = 0 }
        let want = wantsCut(mode: mode, level: b.current, planCut: p.cut)
        let need = want || mode == .holding && top < floor  // a range's bottom under 80 needs the switch only while it rests (want)
        var note = steerCharger(need: need, want: want, deep: c.calib == 2)
        // An automatic run down the charger could not follow (no helper, AlDente, another app's cut) ends quietly; the next
        // step tries again, so it starts once the cause is gone. Its note would wrongly talk about limits under 80.
        if c.autoRun, !cutNow { c.runDown = nil; c.autoRun = false; note = nil }
        // An old helper cannot run the battery down that far, and with no helper the run down never starts: end the cycle.
        if note == .oldHelper || c.calib == 2 && note == .noHelper { c.calib = 0 }
        steerLight(ledDark(settings.led, plugged: b.external == true, charging: b.charging == true))
        // Only a pause that really holds: on the charger at 80 and up (the Mac's limit), or with our cut (under 80). Unplugged is not paused.
        let paused = active && c.pausedAt != nil && (cutNow || b.external == true && level >= floor)
        // Only above our level on the charger: once the battery is back down, the flag alone never changes the text.
        let calibrating = mode == .holding && !cutNow && b.external == true && level > max(top, macFloor) && macCal
        let keep = settings.keepOnQuit && mode == .holding && sched == nil && p.mac == limit && limit >= macFloor && !p.cut && !intelMac
        let s = Snapshot(level: level, plugged: b.external ?? false, charging: b.charging ?? false, limit: top, mode: mode, mac: mac, cut: cutNow, cutNote: note,
                         heatOn: heatOn, sailing: sailOn, bottom: clampBottom(bottom, limit: top), tempF: b.tempF, paused: paused, resting: c.resting, calibrating: calibrating,
                         runDown: c.runDown, autoRun: c.autoRun, calib: c.calib, scheduled: sched.map { Scheduled(name: $0.0.name, until: $0.1, back: limit) },
                         lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, keepsOnQuit: keep, helperOld: helperOld, settings: settings, health: health)
        DispatchQueue.main.async {
            keepLimitOnExit = keep
            self.snap = s
            let before = self.anim
            self.refreshAnimation()
            if self.anim == before { self.onIcon() }  // a changed anim has already redrawn the icon (its didSet)
        }
    }

    // Work queue. need: the settings may switch the charger now (under 80, the range's bottom under 80, or a heat pause
    // under 80); each step then asks the helper (which also tells it the app is alive) for power off (want) or on.
    // Otherwise only a cut of ours is given back. AlDente running or the lid closed: Charge Keeper does not switch the charger.
    private func steerCharger(need: Bool, want: Bool, deep: Bool) -> CutNote? {
        let aldente = need && self.aldente
        guard need || cutNow else { return nil }
        let lid = need && lidClosed()  // cutting power can put a Mac with an outside screen to sleep
        let w = cutsNow(want: want, aldente: aldente, lid: lid)
        let r = charger.send(byte: w ? (deep ? cmdDeep : cmdCut) : cmdOn)
        if w && deep && r == replyOn { helperOld = true; cutNow = false; charger.disconnect(); return .oldHelper }  // an old helper reads "d" as power on
        cutNow = r == replyCut
        if !need || !w && r == replyOn { charger.disconnect() }  // nothing of ours is off: no need to keep the line open
        if aldente { return .aldente }
        guard need else { return nil }
        if r == replyBusy { return .otherApp }
        if r != replyCut && r != replyOn { return .noHelper }
        return lid ? .lidClosed : nil
    }

    // Work queue. The MagSafe light: dark asked again every step while wanted (a restarted helper has given it back), normal once.
    private func steerLight(_ dark: Bool) {
        guard !helperOld, dark || ledIsDark else { return }
        let r = ledLine.send(byte: dark ? cmdLedDark : cmdLedNormal)
        if r != nil && r != replyDone && r != replyErr { helperOld = true }
        ledIsDark = dark && r == replyDone
        if !ledIsDark { ledLine.disconnect() }
    }

    // Main thread. The timer runs only while charging with a screen awake; any other state stops it and shows today's plain icon.
    // Only the number-in-battery icon has the sweep; the other styles, and the Look tab's switch off, show a still picture.
    private func refreshAnimation() {
        let charging = isCharging(snap)
        let look = snap.settings.look
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !look.sweep || look.icon != .numberInBattery
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

    func panel(open: Bool) { panelOpen = open; if open { bar = anim } else { helperFailed = false } }
    func setLimit(_ v: Int) {
        work.async {
            let new = clampLimit(v)
            if new != self.limit { self.c.resting = false }  // a new top: charge up to it first (a top under the level rests again at once)
            self.limit = new; UserDefaults.standard.set(new, forKey: "limit")
            self.bottom = clampBottom(self.bottom, limit: new)  // moving the top down pushes the bottom down too
            self.step()
        }
    }
    func setBottom(_ v: Int) { work.async { self.bottom = clampBottom(v, limit: self.limit); self.step() } }
    func setHeat(_ on: Bool) { work.async { self.heatOn = on; self.step() } }  // off ends a pause straight away
    func setSailing(_ on: Bool) { work.async { self.sailOn = on; self.step() } }
    func chargeToFullOnce() { work.async { self.c.runDown = nil; self.c.calib = 0; self.c.fullOnce = true; self.step() } }
    func backToLimit() { work.async { self.c.fullOnce = false; self.step() } }
    // Panel 4's choice. Charge Keeper: take over the limit that is on now. The Mac's own: Charge Keeper only shows the level, also after a restart.
    func choose(macLimit: Bool) {
        work.async {
            self.useMac = macLimit
            self.aside = false; self.adopt = !macLimit; self.step()
        }
    }
    // Charging is put back (or, with "Keep my limit", left on) here on the work queue, not in exit() on the screen thread: it can
    // take seconds and would freeze the panel. exit()'s handler still runs and finds nothing left; it covers log out and restart.
    func quit() {
        let keep = keepLimitOnExit  // main thread
        work.async {
            self.quitting = true
            if keep { activeLimiter?.leaveOn(); UserDefaults.standard.set(true, forKey: "leftOn"); UserDefaults.standard.synchronize() } else { activeLimiter?.release(final: true) }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
    // Mockup v3
    func startRunDown() { work.async { self.c.fullOnce = false; self.c.calib = 0; self.c.runDown = self.c.lastTop; self.step() } }  // the limit in force, so a link never cuts a schedule's charge short
    // Also "Stop This Time": no automatic run down starts again until the level is under the limit.
    func stopRunDown() { work.async { self.c.runDown = nil; self.c.autoHeld = true; self.step() } }
    // Only while holding, as the Settings button: otherwise the next step ends it at once and pushes the schedule back (a link can call this anytime).
    func startCalibration() { work.async { guard self.wasHolding, self.c.calib == 0 else { return }; self.c.runDown = nil; self.c.fullOnce = false; self.c.calib = 1; self.step() } }
    func cancelCalibration() { work.async { self.c.calib = 0; self.step() } }
    func skipSchedule() { work.async { if let (s, end) = activeSchedule(self.settings.schedules, now: Date(), skipped: self.skipped) { self.skipped[s.id] = end }; self.step() } }
    func setLowPower(_ on: Bool) {
        work.async {
            guard !self.helperOld else { return self.step() }
            let r = self.charger.send(byte: on ? cmdLowOn : cmdLowOff)
            if r != nil && r != replyDone && r != replyErr { self.helperOld = true }
            if !self.cutNow { self.charger.disconnect() }
            self.step()
            self.work.asyncAfter(deadline: .now() + 1.5) { self.step() }  // macOS reports the new low power state a moment later
        }
    }
    // The panel's Install/Update Charger Helper button: runs the bundled install script (macOS asks for the Mac password once).
    // Off the screen thread, as the password box waits for the user. A fresh helper understands every command again.
    @Published private(set) var helperBusy = false
    @Published private(set) var helperFailed = false  // the last install did not finish (cancelled password box included)
    func installHelper() {
        guard !helperBusy else { return }
        guard let script = Bundle.main.path(forResource: "install-helper", ofType: "sh") else { helperFailed = true; return }
        helperBusy = true; helperFailed = false
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [script]
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            self.work.async {
                if ok {  // a cancelled password box or a failed install leaves the old state, old helper included
                    self.helperOld = false; self.cutNow = false; self.ledIsDark = false  // replacing the helper switched power and light back on
                    self.charger.disconnect(); self.ledLine.disconnect()
                }
                self.step()
                DispatchQueue.main.async { self.helperBusy = false; self.helperFailed = !ok }
            }
        }
    }
    func refreshHealth() { work.async { self.healthRead = .distantPast; self.step() } }
    func update(_ change: @escaping (inout KeeperSettings) -> Void) { work.async { change(&self.settings); self.step() } }
    func open(_ link: LinkAction) {
        switch link {
        case .limit(let v): work.async { self.c.runDown = nil; self.c.calib = 0; self.c.fullOnce = false }; setLimit(v)
        case .full: chargeToFullOnce()
        case .runDown: startRunDown()
        case .heat(let on): setHeat(on)
        case .sailing(let on): setSailing(on)
        case .lowPower(let on): setLowPower(on)
        case .calibration(let on): if on { startCalibration() } else { cancelCalibration() }
        }
    }
}

let wakeChecks: [TimeInterval] = [0, 5, 20]  // seconds after wake
