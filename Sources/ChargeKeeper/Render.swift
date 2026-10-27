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
            HStack { Spacer(); Image(nsImage: fill.map { chargingIcon(level: snap.level, fill: $0, dark: dark) } ?? makeBattery(level: snap.level)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 5)); Text("Mon 9:41") }
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
        ("stepped-aside", Snapshot(level: 80, plugged: true, charging: false, limit: 85, mode: .steppedAside, mac: LimitState(enabled: true, limit: 90))),
        ("stepped-aside-off", Snapshot(level: 80, plugged: true, charging: true, limit: 85, mode: .steppedAside, mac: LimitState(enabled: false, limit: 85))),
        ("mac-own-limit", Snapshot(level: 80, plugged: true, charging: false, limit: 85, mode: .macLimit, mac: LimitState(enabled: true, limit: 90))),
        ("mac-own-limit-off", Snapshot(level: 62, plugged: true, charging: true, limit: 85, mode: .macLimit, mac: LimitState(enabled: false, limit: 100))),
        ("below80-coming-down", Snapshot(level: 72, plugged: false, charging: false, limit: 60, mode: .holding, cut: true)),
        ("below80-holding", Snapshot(level: 58, plugged: false, charging: false, limit: 60, mode: .holding, cut: true)),
        ("below80-no-helper", Snapshot(level: 70, plugged: true, charging: true, limit: 60, mode: .holding, cutNote: .noHelper)),
        ("below80-aldente", Snapshot(level: 80, plugged: true, charging: false, limit: 60, mode: .holding, cutNote: .aldente)),
    ]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var ok = true
    for (name, snap) in states {
        for dark in [false, true] {
            ok = save(Stage(snap: snap, dark: dark), dark: dark, scale: 2, to: "\(dir)/panel-\(name)-\(dark ? "dark" : "light").png") && ok
        }
    }
    // The icon alone, drawn 8 times larger (scale 2 = real size on a retina screen), in the colour the menu bar would give it (black on light, white on dark).
    for dark in [false, true] {
        let tone = dark ? "dark" : "light"
        for (name, lv) in [("9", 9), ("54-on-battery", 54), ("62", 62), ("80-holding", 80), ("100", 100)] {
            ok = saveIcon(makeBattery(level: lv), dark: dark, to: "\(dir)/icon-\(name)-\(tone).png") && ok
        }
        for (name, f) in [("sliver", iconFill(0)), ("mid", 0.5), ("full", 1.0), ("reduce-motion", iconFill(stillSweep))] {
            ok = saveIcon(chargingIcon(level: 62, fill: f, dark: dark), dark: dark, to: "\(dir)/icon-charging-\(name)-\(tone).png") && ok
        }
        for lv in [0, 6, 9, 100] {  // digits with holes: the green must be cleared inside them too
            ok = saveIcon(chargingIcon(level: lv, fill: 1.0, dark: dark), dark: dark, to: "\(dir)/icon-charging-\(lv)-\(tone).png") && ok
        }
        for lv in [9, 62, 80, 100] { for k in [2, 8] {  // k = 2: real size (2x screen pixels, 1:1 on this Mac); 8: enlarged. For the before/after pictures
            ok = saveIcon(makeBattery(level: lv), dark: dark, scale: k, to: "\(dir)/real\(k)-\(lv)-holding-\(tone).png") && ok
            ok = saveIcon(chargingIcon(level: lv, fill: iconFill(stillSweep), dark: dark), dark: dark, scale: k, to: "\(dir)/real\(k)-\(lv)-charging-\(tone).png") && ok
        } }
        // The panel bar while charging (start, middle, end of a round), and the Reduce Motion still.
        let charging = Snapshot(level: 62, plugged: true, charging: true, limit: 80, mode: .holding)
        for (name, b) in [("start", 0.0), ("mid", 0.5), ("end", 1.0), ("reduce-motion", stillSweep)] {
            ok = save(Stage(snap: charging, dark: dark, bar: b, fill: iconFill(stillSweep)), dark: dark, scale: 2, to: "\(dir)/panel-charging-\(name)-\(tone).png") && ok
        }
    }
    ok = saveStrips(to: dir) && ok
    return ok
}

// Frame strips of the charging icon over one 2 s round at 12 (before), 4 and 3 (new) picture changes per second, light and dark, real size and enlarged.
@MainActor private func saveStrips(to dir: String) -> Bool {
    for dark in [false, true] { for (k, perRow) in [(2, 12), (6, 6)] {
        let rates = [12, 4, 3], gap = 10 * k / 2, cell = 30 * k + gap, rowH = 15 * k + gap, head = 22
        let rowsFor = { (r: Int) in (2 * r + perRow - 1) / perRow }
        let w = perRow * cell + gap, h = rates.map { head + rowsFor($0) * rowH + gap }.reduce(0, +)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        var top = h
        for r in rates {
            let vals = (0..<2 * r).map { sweepAmount(Double($0) / Double(r)) }
            let changes = zip(vals, vals.dropFirst() + [vals[0]]).filter { $0 != $1 }.count
            let label = "\(r) per second\(r == 12 ? " (today)" : r == 3 ? " (new)" : ""): \(2 * r) frames per round, \(changes) picture changes"
            print(label)
            label.draw(at: NSPoint(x: gap, y: top - head + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: dark ? NSColor.white : NSColor.black])
            top -= head
            for (i, v) in vals.enumerated() {
                let x = gap + (i % perRow) * cell, y = top - (i / perRow + 1) * rowH + gap
                chargingIcon(level: 62, fill: iconFill(v), dark: dark).draw(in: NSRect(x: x, y: y, width: 30 * k, height: 15 * k))
            }
            top -= rowsFor(r) * rowH + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        let path = "\(dir)/sweep-strips-\(k == 2 ? "real" : "enlarged")-\(dark ? "dark" : "light").png"
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return false }
        print(path)
    } }
    return true
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

@MainActor private func saveIcon(_ icon: NSImage, dark: Bool, scale k: Int = 8, to path: String) -> Bool {
    let w = 300 * k / 8, h = 150 * k / 8  // k = 8: the 300 x 150 canvas of the approved pictures
    func newRep() -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }
    guard let mask = newRep(), let mctx = NSGraphicsContext(bitmapImageRep: mask) else { return false }
    let box = NSRect(x: 30 * k / 8, y: 15 * k / 8, width: 30 * k, height: 15 * k)  // the 30 x 15 icon, k times larger
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
