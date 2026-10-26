// The menu-bar icon: the shield-battery drawn in the approved mockup (a 28 x 14 drawing), as a template image,
// so macOS tints it for a light or a dark menu bar. The check mark is cut out of the shield.
import AppKit

let shieldBattery: NSImage = {
    let img = NSImage(size: NSSize(width: 22, height: 11), flipped: true) { _ in
        guard let cg = NSGraphicsContext.current?.cgContext else { return false }
        cg.scaleBy(x: 22.0 / 28.0, y: 22.0 / 28.0)
        NSColor.black.set()
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
    img.isTemplate = true
    return img
}()
