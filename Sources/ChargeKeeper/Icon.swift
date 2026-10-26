// The menu-bar icon: the shield-battery drawn in the approved mockup (a 28 x 14 drawing), as a template image,
// so macOS tints it for a light or a dark menu bar. The check mark is cut out of the shield.
import AppKit

// fill = nil: the plain icon. fill = 0...1: the charging picture, a green fill inside the battery behind the shield, in colour,
// so the outline is drawn in `ink` (black or white to match the menu bar) instead of being tinted by macOS.
func makeShieldBattery(fill: Double? = nil, ink: NSColor = .black, green: NSColor = .systemGreen) -> NSImage {
    let img = NSImage(size: NSSize(width: 22, height: 11), flipped: true) { _ in
        guard let cg = NSGraphicsContext.current?.cgContext else { return false }
        cg.scaleBy(x: 22.0 / 28.0, y: 22.0 / 28.0)
        if let f = fill {
            green.setFill()
            let w = 20.4 * min(1, max(0, f)), r = min(2.2, w / 2)  // a sliver narrower than two corners must not become a blob
            NSBezierPath(roundedRect: NSRect(x: 1.8, y: 2.3, width: w, height: 9.4), xRadius: r, yRadius: r).fill()
        }
        ink.set()
        let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 1.5, width: 22, height: 11), xRadius: 3, yRadius: 3)
        body.lineWidth = 1.4
        body.stroke()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 5, width: 2.5, height: 4), xRadius: 1, yRadius: 1).fill()
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: 12, y: 3.4))
        shield.line(to: NSPoint(x: 16.2, y: 4.9))
        shield.line(to: NSPoint(x: 16.2, y: 7.5))
        shield.curve(to: NSPoint(x: 12, y: 11.5), controlPoint1: NSPoint(x: 16.2, y: 9.5), controlPoint2: NSPoint(x: 14.4, y: 10.7))
        shield.curve(to: NSPoint(x: 7.8, y: 7.5), controlPoint1: NSPoint(x: 9.6, y: 10.7), controlPoint2: NSPoint(x: 7.8, y: 9.5))
        shield.line(to: NSPoint(x: 7.8, y: 4.9))
        shield.close()
        shield.fill()
        cg.setBlendMode(.clear)
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: 10.6, y: 7.2))
        tick.line(to: NSPoint(x: 11.6, y: 8.2))
        tick.line(to: NSPoint(x: 13.5, y: 6.2))
        tick.lineWidth = 1.1
        tick.stroke()
        return true
    }
    img.isTemplate = fill == nil
    return img
}

let shieldBattery = makeShieldBattery()

// The mockup's greens: the panel bar's green, a softer one on a dark menu bar.
func chargingIcon(fill: Double, dark: Bool) -> NSImage {
    makeShieldBattery(fill: fill, ink: dark ? .white : .black, green: dark ? NSColor(srgbRed: 0.275, green: 0.769, blue: 0.416, alpha: 1) : NSColor(srgbRed: 0.184, green: 0.659, blue: 0.31, alpha: 1))
}

// One 2 second round, as in the approved mockup: grows from a sliver to full over the first 80%, rests, starts over (ease in-out).
func sweepAmount(_ t: Double) -> Double {
    let x = min(1, (t.truncatingRemainder(dividingBy: 2)) / 2 / 0.8)
    return x < 0.5 ? 2 * x * x : 1 - 2 * (1 - x) * (1 - x)
}
