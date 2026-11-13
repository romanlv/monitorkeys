// Draws the app icon: a monitor whose screen fades from dim to bright, with a sun on it.
// Usage: swift scripts/make-icon.swift <output.png>   (1024×1024; scripts/make-icon.sh builds the .icns)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Background tile on Apple's macOS icon grid: 824 pt squircle, centred, with a soft drop shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
rgb(0x1B2340).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(0x2A3A6E), rgb(0x141A33)])!.draw(in: tilePath, angle: -90)

// Monitor: bezel, screen, neck and foot.
let bezel = NSRect(x: 196, y: 330, width: 632, height: 440)
let screen = bezel.insetBy(dx: 26, dy: 26)
let neck = NSBezierPath()
neck.move(to: NSPoint(x: 462, y: 330))
neck.line(to: NSPoint(x: 562, y: 330))
neck.line(to: NSPoint(x: 584, y: 236))
neck.line(to: NSPoint(x: 440, y: 236))
neck.close()
let foot = NSBezierPath(roundedRect: NSRect(x: 372, y: 214, width: 280, height: 34), xRadius: 17, yRadius: 17)

NSGradient(colors: [rgb(0xC9CED9), rgb(0x8E95A6)])!.draw(in: neck, angle: -90)
NSGradient(colors: [rgb(0xDCE0E8), rgb(0xA3A9B8)])!.draw(in: foot, angle: -90)

let bezelPath = NSBezierPath(roundedRect: bezel, xRadius: 44, yRadius: 44)
NSGraphicsContext.saveGraphicsState()
let bezelShadow = NSShadow()
bezelShadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
bezelShadow.shadowOffset = NSSize(width: 0, height: -10)
bezelShadow.shadowBlurRadius = 24
bezelShadow.set()
rgb(0x0B0E18).setFill()
bezelPath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(0x2B2F3A), rgb(0x0E1017)])!.draw(in: bezelPath, angle: -90)

// Screen: dark on the left, warm and bright on the right, the range the slider covers.
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 22, yRadius: 22)
NSGradient(colorsAndLocations:
    (rgb(0x0F1530), 0.0), (rgb(0x3B4C8C), 0.45), (rgb(0xF2B24C), 0.85), (rgb(0xFFE6A8), 1.0))!
    .draw(in: screenPath, angle: 0)
// A soft glow behind the sun.
NSGraphicsContext.saveGraphicsState()
screenPath.addClip()
let sunCentre = NSPoint(x: screen.midX + 40, y: screen.midY)
NSGradient(colors: [rgb(0xFFF4D0, 0.85), rgb(0xFFD27A, 0)])!
    .draw(fromCenter: sunCentre, radius: 0, toCenter: sunCentre, radius: 260, options: [])
NSGraphicsContext.restoreGraphicsState()

// Sun: disc and rays, drawn so it stays crisp at every size.
ctx.saveGState()
ctx.translateBy(x: sunCentre.x, y: sunCentre.y)
let sunColor = rgb(0xFFFFFF)
sunColor.setFill()
NSBezierPath(ovalIn: NSRect(x: -74, y: -74, width: 148, height: 148)).fill()
for i in 0..<8 {
    ctx.saveGState()
    ctx.rotate(by: CGFloat(i) * .pi / 4)
    NSBezierPath(roundedRect: NSRect(x: -14, y: 104, width: 28, height: 58), xRadius: 14, yRadius: 14).fill()
    ctx.restoreGState()
}
ctx.restoreGState()

// A thin highlight along the top of the bezel.
NSGraphicsContext.saveGraphicsState()
bezelPath.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: bezel.minX, y: bezel.maxY - 26, width: bezel.width, height: 26), angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
