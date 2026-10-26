// The menu-bar app, following the approved mockup v1 (panels 1 to 3; panel 4 is a note only, panel 5 is dropped:
// no password is needed).
import SwiftUI
import AppKit

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
        work.async { self.limiter?.clearLeftover(); self.step() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.work.async { self.step() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            self.work.async { self.step() }  // sleep may have undone the limit; step() reads it and re-applies
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

struct KeeperApp: App {  // started from main.swift
    @StateObject private var keeper = Keeper()
    var body: some Scene {
        MenuBarExtra {
            Panel(keeper: keeper)
        } label: {
            HStack(spacing: 4) { Image(systemName: "checkmark.shield"); Text("\(keeper.snap.level)%") }
        }
        .menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @ObservedObject var keeper: Keeper
    @State private var draft = 80.0
    var body: some View {
        let s = keeper.snap
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(s.level)%").font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Spacer()
                Text(statusText(s)).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(100, max(0, s.level))), total: 100).tint(.green)
            switch s.mode {
            case .foreign:
                Note("Your Mac has its own charge limit turned on.", "Two limits can get in each other's way, so Charge Keeper is waiting. Turn off the Mac's limit in Battery settings and Charge Keeper takes over by itself.")
            case .unsupported:
                Note("This Mac has no built-in charge limit.", "Charge Keeper cannot hold a level here.")
            case .failed(let why):
                Note("Charge Keeper could not set the limit.", why)
            case .fullOnce:
                Note("Your limit is paused.", "When the battery reaches 100%, Charge Keeper goes back to holding at \(s.limit)% by itself.")
                Button("Stop and go back to \(s.limit)%") { keeper.backToLimit() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            case .holding, .starting:
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Stop charging at").bold(); Spacer(); Text("\(Int(draft))%").bold() }
                    Slider(value: $draft, in: Double(limitRange.lowerBound)...Double(limitRange.upperBound), step: 5) { editing in
                        if !editing { keeper.setLimit(Int(draft)) }  // applied on release, not on every tick
                    }
                    HStack { Text("\(limitRange.lowerBound)%"); Spacer(); Text("\(limitRange.upperBound)%") }.font(.caption).foregroundStyle(.secondary)
                }
                Button("Charge to full once") { keeper.chargeToFullOnce() }.frame(maxWidth: .infinity)
            }
            Divider()
            Button("Quit (charging turns back on)") { keeper.quit() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 272)
        .onAppear { draft = Double(s.limit) }
        .onChange(of: s.limit) { draft = Double($0) }
    }
}

struct Note: View {
    let title: String, text: String
    init(_ title: String, _ text: String) { self.title = title; self.text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).bold().foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
