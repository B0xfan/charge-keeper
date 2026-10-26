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
        let path = digitsPath(level)
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

// The mockup's greens: the panel bar's green, a softer one on a dark menu bar.
func chargingIcon(level: Int, fill: Double, dark: Bool) -> NSImage {
    makeBattery(level: level, fill: fill, ink: dark ? .white : .black, green: dark ? NSColor(srgbRed: 0.275, green: 0.769, blue: 0.416, alpha: 1) : NSColor(srgbRed: 0.184, green: 0.659, blue: 0.31, alpha: 1))
}

// One 2 second round, as in the approved mockup: grows from a sliver to full over the first 80%, rests, starts over (ease in-out).
func sweepAmount(_ t: Double) -> Double {
    let x = min(1, (t.truncatingRemainder(dividingBy: 2)) / 2 / 0.8)
    return x < 0.5 ? 2 * x * x : 1 - 2 * (1 - x) * (1 - x)
}

// The digits as one outline (bold, equal-width), centred on a point, for a flipped (y down) drawing.
// The outline path, not styled text, because stroking styled text leaves stray lines where glyph parts overlap.
private var digitsCache: (level: Int, path: CGPath)?  // the icon is redrawn 12 times a second, the level changes rarely
private func digitsPath(_ level: Int) -> CGPath {
    if let c = digitsCache, c.level == level { return c.path }
    let text = "\(level)", centreX: CGFloat = 13.5, centreY: CGFloat = 7.9
    let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold) as CTFont
    var chars = Array(text.utf16), glyphs = [CGGlyph](repeating: 0, count: chars.count)
    CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    let total = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
    let out = CGMutablePath()
    var x = centreX - CGFloat(total) / 2
    for (g, adv) in zip(glyphs, advances) {
        if let gp = CTFontCreatePathForGlyph(font, g, nil) {
            out.addPath(gp, transform: CGAffineTransform(translationX: x, y: centreY + CTFontGetCapHeight(font) / 2).scaledBy(x: 1, y: -1))
        }
        x += adv.width
    }
    digitsCache = (level, out)
    return out
}
