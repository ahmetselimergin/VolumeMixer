// Draws the app icon: violet squircle with three mixer faders. Usage: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body centered on a 1024 canvas, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()
NSGradient(colors: [
    NSColor(srgbRed: 0.53, green: 0.44, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.36, green: 0.24, blue: 0.86, alpha: 1),
    NSColor(srgbRed: 0.17, green: 0.10, blue: 0.46, alpha: 1),
])!.draw(in: body, angle: -90)
// Top sheen
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
ctx.restoreGState()

// Faders
let levels: [CGFloat] = [0.38, 0.78, 0.56]
let trackWidth: CGFloat = 64
let trackTop: CGFloat = 790, trackBottom: CGFloat = 234
let spacing: CGFloat = 188
for (i, level) in levels.enumerated() {
    let cx = size / 2 + CGFloat(i - 1) * spacing
    let track = CGRect(x: cx - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackTop - trackBottom)
    NSColor.black.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: track, xRadius: trackWidth / 2, yRadius: trackWidth / 2).fill()

    let knobY = trackBottom + (trackTop - trackBottom) * level
    let filled = CGRect(x: track.minX, y: trackBottom, width: trackWidth, height: knobY - trackBottom)
    NSGradient(colors: [NSColor(srgbRed: 0.55, green: 0.95, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: filled, xRadius: trackWidth / 2, yRadius: trackWidth / 2), angle: 90)

    let knobSize: CGFloat = 138
    let knob = CGRect(x: cx - knobSize / 2, y: knobY - knobSize / 2, width: knobSize, height: knobSize)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: knob).fill()
    ctx.restoreGState()
    NSColor(srgbRed: 0.36, green: 0.24, blue: 0.86, alpha: 1).setFill()
    NSBezierPath(ovalIn: knob.insetBy(dx: 50, dy: 50)).fill()
}

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
