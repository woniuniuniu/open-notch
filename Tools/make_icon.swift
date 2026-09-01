import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift make_icon.swift output.png\n", stderr)
    exit(2)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

let canvas = NSRect(x: 52, y: 52, width: 920, height: 920)
NSColor(calibratedRed: 0.105, green: 0.115, blue: 0.125, alpha: 1).setFill()
NSBezierPath(roundedRect: canvas, xRadius: 210, yRadius: 210).fill()

// Three menu-bar regions form a compact, recognizable "open bar" mark.
let barY: CGFloat = 392
let barHeight: CGFloat = 190
let segments = [
    NSRect(x: 170, y: barY, width: 208, height: barHeight),
    NSRect(x: 408, y: barY, width: 208, height: barHeight),
    NSRect(x: 646, y: barY, width: 208, height: barHeight),
]
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
for segment in segments {
    NSBezierPath(roundedRect: segment, xRadius: 42, yRadius: 42).fill()
}

// The green gate is the visible/hidden boundary and remains clear at 16 px.
NSColor(calibratedRed: 0.16, green: 0.72, blue: 0.38, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 444, y: 326, width: 136, height: 322), xRadius: 52, yRadius: 52).fill()

NSColor(calibratedRed: 0.105, green: 0.115, blue: 0.125, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 478, y: 430, width: 68, height: 114), xRadius: 25, yRadius: 25).fill()

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
