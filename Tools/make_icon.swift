import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let tile = NSRect(x: 72, y: 72, width: 880, height: 880)
NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.12, alpha: 1).setFill()
NSBezierPath(roundedRect: tile, xRadius: 205, yRadius: 205).fill()

let inset = tile.insetBy(dx: 112, dy: 112)
NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
NSBezierPath(roundedRect: inset, xRadius: 92, yRadius: 92).fill()

let topBar = NSRect(x: 250, y: 696, width: 524, height: 54)
NSColor.white.setFill()
NSBezierPath(roundedRect: topBar, xRadius: 27, yRadius: 27).fill()

let notch = NSBezierPath()
notch.move(to: NSPoint(x: 402, y: 750))
notch.line(to: NSPoint(x: 622, y: 750))
notch.curve(to: NSPoint(x: 574, y: 666), controlPoint1: NSPoint(x: 620, y: 708), controlPoint2: NSPoint(x: 606, y: 666))
notch.line(to: NSPoint(x: 450, y: 666))
notch.curve(to: NSPoint(x: 402, y: 750), controlPoint1: NSPoint(x: 418, y: 666), controlPoint2: NSPoint(x: 404, y: 708))
notch.close()
NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.12, alpha: 1).setFill()
notch.fill()

let dots: [(CGFloat, NSColor)] = [
    (350, NSColor(calibratedRed: 0.25, green: 0.78, blue: 0.67, alpha: 1)),
    (512, NSColor(calibratedRed: 0.96, green: 0.63, blue: 0.25, alpha: 1)),
    (674, NSColor(calibratedWhite: 0.92, alpha: 1)),
]
for (x, color) in dots {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - 42, y: 380, width: 84, height: 84)).fill()
}

NSColor(calibratedWhite: 1, alpha: 0.9).setStroke()
let line = NSBezierPath()
line.lineWidth = 24
line.lineCapStyle = .round
line.move(to: NSPoint(x: 326, y: 548))
line.line(to: NSPoint(x: 698, y: 548))
line.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Unable to render app icon")
}
try png.write(to: URL(fileURLWithPath: output))
