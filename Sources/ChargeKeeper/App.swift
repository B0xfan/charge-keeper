// The menu-bar app, following the approved mockup v1 (panels 1 to 4; panel 5 is dropped: no password is needed).
// Panel 4's choice is also shown when someone else changes the limit while Charge Keeper holds (it steps aside instead of setting it back).
import SwiftUI
import AppKit

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
        let host = NSHostingController(rootView: PanelHost(keeper: keeper, openSettings: { [weak self] in self?.openSettings() }))
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
        item.button?.setAccessibilityValue("\(s.level)%, \(statusText(s))")  // VoiceOver reads the level, not just the name
    }

    // Mockup v3: one Settings window, made on first use and reused.
    private var settingsWindow: NSWindow?
    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsHost(keeper: keeper)))
            w.title = "Charge Keeper Settings"
            w.styleMask = [.titled, .closable]  // fixed size: every section fits
            w.isReleasedWhenClosed = false
            w.center()  // first time only: later it reopens where the user left it
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // chargekeeper:// links (Info.plist), for Shortcuts' "Open URLs" action, scripts or a bookmark.
    func application(_ application: NSApplication, open urls: [URL]) { for u in urls { if let a = linkAction(u) { keeper.open(a) } } }

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

// Never shown (accessory app), but its key equivalents make Cmd-C/V/X/A/Z work in text fields and Cmd-W close Settings.
private func keyMenu() -> NSMenu {
    let main = NSMenu()
    for (title, items) in [("Edit", [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")]),
                           ("Window", [("Close", "performClose:", "w")])] {
        let m = NSMenu(title: title)
        for (t, a, k) in items { m.addItem(withTitle: t, action: Selector(a), keyEquivalent: k) }
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
    }
    return main
}

func runApp() -> Never {
    let app = NSApplication.shared
    let controller = StatusController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.mainMenu = keyMenu()
    withExtendedLifetime(controller) { app.run() }
    exit(0)
}
