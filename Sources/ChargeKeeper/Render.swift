// --render <folder>: draws the panel and the menu-bar icon off-screen into PNG files (light and dark), so the look can be
// checked against the mockup without opening a window or touching the Mac's charge limit. Not used by the app itself.
import SwiftUI
import AppKit

private struct Stage: View {
    let snap: Snapshot
    let dark: Bool
    var bar = 0.0
    var fill: Double? = nil
    var body: some View {
        VStack(spacing: 8) {
            HStack { Spacer(); MenuBarLabel(level: snap.level, fill: fill).padding(.horizontal, 6).padding(.vertical, 2).background(Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 5)); Text("Mon 9:41") }
                .font(.system(size: 13)).padding(.horizontal, 12).frame(width: 340, height: 26).background(dark ? Color(white: 0.12, opacity: 0.6) : Color.white.opacity(0.55))
            Panel(s: snap, bar: bar)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.14)))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            Spacer().frame(height: 10)
        }
        .frame(width: 340)
        .background(LinearGradient(colors: dark ? [Color(red: 0.17, green: 0.21, blue: 0.31), Color(red: 0.11, green: 0.13, blue: 0.22)] : [Color(red: 0.79, green: 0.83, blue: 0.9), Color(red: 0.66, green: 0.73, blue: 0.84)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

@MainActor func renderAll(to dir: String) -> Bool {
    _ = NSApplication.shared
    let states: [(String, Snapshot)] = [
        ("normal", Snapshot(level: 80, plugged: true, charging: false, limit: 80, mode: .holding)),
        ("charging", Snapshot(level: 62, plugged: true, charging: true, limit: 80, mode: .holding)),
        ("onbattery", Snapshot(level: 54, plugged: false, charging: false, limit: 80, mode: .holding)),
        ("full-once", Snapshot(level: 80, plugged: true, charging: true, limit: 80, mode: .fullOnce)),
        ("mac-limit-on", Snapshot(level: 80, plugged: true, charging: false, limit: 80, mode: .foreign)),
    ]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var ok = true
    for (name, snap) in states {
        for dark in [false, true] {
            ok = save(Stage(snap: snap, dark: dark), dark: dark, scale: 2, to: "\(dir)/panel-\(name)-\(dark ? "dark" : "light").png") && ok
        }
    }
    // The icon alone, drawn 8 times larger, in the colour the menu bar would give it (black on light, white on dark).
    for dark in [false, true] {
        let tone = dark ? "dark" : "light"
        ok = saveIcon(shieldBattery, dark: dark, to: "\(dir)/icon-\(tone).png") && ok
        for (name, f) in [("sliver", iconFill(0)), ("mid", 0.5), ("full", 1.0), ("reduce-motion", iconFill(stillSweep))] {
            ok = saveIcon(chargingIcon(fill: f, dark: dark), dark: dark, to: "\(dir)/icon-charging-\(name)-\(tone).png") && ok
        }
        // The panel bar while charging (start, middle, end of a round), and the Reduce Motion still.
        let charging = Snapshot(level: 62, plugged: true, charging: true, limit: 80, mode: .holding)
        for (name, b) in [("start", 0.0), ("mid", 0.5), ("end", 1.0), ("reduce-motion", stillSweep)] {
            ok = save(Stage(snap: charging, dark: dark, bar: b, fill: iconFill(stillSweep)), dark: dark, scale: 2, to: "\(dir)/panel-charging-\(name)-\(tone).png") && ok
        }
    }
    return ok
}

@MainActor private func save<V: View>(_ view: V, dark: Bool, scale: Int, to path: String) -> Bool {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * scale, pixelsHigh: Int(host.bounds.height) * scale,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
    rep.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return false }
    print(path)
    return true
}

@MainActor private func saveIcon(_ icon: NSImage, dark: Bool, to path: String) -> Bool {
    let w = 240, h = 128
    func newRep() -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }
    guard let mask = newRep(), let mctx = NSGraphicsContext(bitmapImageRep: mask) else { return false }
    let box = NSRect(x: 32, y: 20, width: 176, height: 88)  // the 22 x 11 icon, 8 times larger
    let all = NSRect(x: 0, y: 0, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = mctx
    icon.draw(in: box)
    if icon.isTemplate {  // a template is tinted by macOS: black on a light bar, white on a dark one
        (dark ? NSColor.white : NSColor.black).setFill()
        all.fill(using: .sourceIn)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let shape = mask.cgImage, let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    cg.setFillColor(gray: dark ? 0.15 : 0.93, alpha: 1)
    cg.fill(all)
    cg.draw(shape, in: all)
    guard let img = cg.makeImage() else { return false }
    let out = NSBitmapImageRep(cgImage: img)
    guard let data = out.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return false }
    print(path)
    return true
}
