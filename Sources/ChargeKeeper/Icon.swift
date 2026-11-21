// The menu-bar icon: the approved bigger battery (a 30 x 15 drawing) with the battery level inside it, no shield.
// Not charging: a template image, so macOS tints it for a light or a dark menu bar.
import AppKit

// fill = nil: the plain icon. fill = 0...1: the charging picture, a green fill inside the battery behind the number, in colour,
// so the outline and digits are drawn in `ink` (black or white to match the menu bar) instead of being tinted by macOS.
func makeBattery(level: Int, fill: Double? = nil, ink: NSColor = .black, green: NSColor = .systemGreen) -> NSImage {
    let img = NSImage(size: NSSize(width: 30, height: 15), flipped: true) { _ in
        guard let cg = NSGraphicsContext.current?.cgContext else { return false }
        if let f = fill {
            green.setFill()
            let w = 24 * min(1, max(0, f)), r = min(2.8, w / 2)  // a sliver narrower than two corners must not become a blob
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: w, height: 12), xRadius: r, yRadius: r).fill()
        }
        ink.set()
        let body = NSBezierPath(roundedRect: NSRect(x: 0.7, y: 0.7, width: 25.6, height: 13.6), xRadius: 3.3, yRadius: 3.3)
        body.lineWidth = 1.3
        body.stroke()
        NSBezierPath(roundedRect: NSRect(x: 27.2, y: 4.5, width: 2.3, height: 6), xRadius: 1, yRadius: 1).fill()
        let path = textPath("\(level)", size: 9.5, weight: .medium, centreX: 13.5, centreY: 7.9).path
        if fill != nil {  // over the green: a thin outline in the bar's own colour (cut out, so the bar shows through)
            cg.setBlendMode(.clear)
            cg.addPath(path); cg.setLineWidth(3.0); cg.setLineJoin(.round); cg.strokePath()
            cg.setBlendMode(.normal)
        }
        cg.addPath(path); cg.setFillColor(ink.cgColor); cg.fillPath()
        return true
    }
    img.isTemplate = fill == nil
    return img
}

// Mockup v4, Settings > Look. The raw values are saved: only ever add cases.
enum IconStyle: Int, Codable, CaseIterable { case numberInBattery, battery, batteryAndNumber, number }

// The other three styles: a battery filled to the level, the level as text ("80%"), or both. fill != nil: charging, so the
// level's fill or the text is green, drawn in colour as makeBattery does; there is no sweep in these (Look's caption says so).
func makeIcon(_ style: IconStyle, level: Int, fill: Double? = nil, ink: NSColor = .black, green: NSColor = .systemGreen) -> NSImage {
    if style == .numberInBattery { return makeBattery(level: level, fill: fill, ink: ink, green: green) }
    let batW: CGFloat = style == .battery ? 30 : style == .batteryAndNumber ? 22 : 0
    let text = style == .battery ? nil : textPath("\(level)%", size: 12, weight: .semibold, centreX: nil, centreY: 7.5)
    let w = text.map { ceil(batW + (batW > 0 ? 3 : 0) + $0.width) } ?? batW
    let img = NSImage(size: NSSize(width: w, height: 15), flipped: true) { _ in
        guard let cg = NSGraphicsContext.current?.cgContext else { return false }
        if batW > 0 {
            let k = batW / 30
            cg.saveGState(); cg.translateBy(x: 0, y: (15 - 15 * k) / 2); cg.scaleBy(x: k, y: k)
            ink.set()
            let body = NSBezierPath(roundedRect: NSRect(x: 0.7, y: 0.7, width: 25.6, height: 13.6), xRadius: 3.3, yRadius: 3.3)
            body.lineWidth = 1.3 / max(k, 0.8)  // the smaller battery keeps a visible outline, as drawn
            body.stroke()
            NSBezierPath(roundedRect: NSRect(x: 27.2, y: 4.5, width: 2.3, height: 6), xRadius: 1, yRadius: 1).fill()
            (fill == nil ? ink : green).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: max(1.5, 22 * CGFloat(min(100, max(0, level))) / 100), height: 10), xRadius: 1.5, yRadius: 1.5).fill()
            cg.restoreGState()
        }
        if let t = text {
            cg.saveGState(); cg.translateBy(x: batW > 0 ? batW + 3 : 0, y: 0)
            cg.addPath(t.path); cg.setFillColor((fill == nil ? ink : green).cgColor); cg.fillPath()
            cg.restoreGState()
        }
        return true
    }
    img.isTemplate = fill == nil
    return img
}

// The mockup's greens: the panel bar's green, a softer one on a dark menu bar.
func chargingIcon(_ style: IconStyle = .numberInBattery, level: Int, fill: Double, dark: Bool) -> NSImage {
    makeIcon(style, level: level, fill: fill, ink: dark ? .white : .black, green: dark ? NSColor(srgbRed: 0.275, green: 0.769, blue: 0.416, alpha: 1) : NSColor(srgbRed: 0.184, green: 0.659, blue: 0.31, alpha: 1))
}

// For the menu bar: the light/dark tone is picked each time macOS draws the picture, so an appearance change (light/dark mode,
// a wallpaper that flips the bar) repaints it correctly even while the animation is stopped (Reduce Motion, screens asleep).
func liveChargingIcon(_ style: IconStyle = .numberInBattery, level: Int, fill: Double) -> NSImage {
    NSImage(size: makeIcon(style, level: level).size, flipped: false) { r in
        chargingIcon(style, level: level, fill: fill, dark: NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua).draw(in: r)
        return true
    }
}

let sweepFPS = 3.0  // picture changes per second at most: each change costs the CPU about 1 to 2% (macOS re-copies the menu-bar item)

// One 2 second round, as in the approved mockup: grows from a sliver to full over the first 80%, rests, starts over (ease in-out).
func sweepAmount(_ t: Double) -> Double {
    let x = min(1, (t.truncatingRemainder(dividingBy: 2)) / 2 / 0.8)
    return x < 0.5 ? 2 * x * x : 1 - 2 * (1 - x) * (1 - x)
}

// Text as one outline (equal-width digits), for a flipped (y down) drawing: centred on centreX, or starting at x 0 when nil.
// The outline path, not styled text, because stroking styled text leaves stray lines where glyph parts overlap.
private var textCache: [String: (path: CGPath, width: CGFloat)] = [:]  // the icon is redrawn a few times a second; at most 101 levels x 3 looks
func textPath(_ text: String, size: CGFloat, weight: NSFont.Weight, centreX: CGFloat?, centreY: CGFloat) -> (path: CGPath, width: CGFloat) {
    let key = "\(text)|\(size)|\(weight.rawValue)|\(centreX ?? -1)|\(centreY)"
    if let c = textCache[key] { return c }
    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) as CTFont
    var chars = Array(text.utf16), glyphs = [CGGlyph](repeating: 0, count: chars.count)
    CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    let total = CGFloat(CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count))
    let out = CGMutablePath()
    var x = centreX.map { $0 - total / 2 } ?? 0
    for (g, adv) in zip(glyphs, advances) {
        if let gp = CTFontCreatePathForGlyph(font, g, nil) {
            out.addPath(gp, transform: CGAffineTransform(translationX: x, y: centreY + CTFontGetCapHeight(font) / 2).scaledBy(x: 1, y: -1))
        }
        x += adv.width
    }
    textCache[key] = (out, total)
    return (out, total)
}
