// Renders the app icon into an .iconset directory: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 body with shadow room.
    let inset = s * 0.098
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    // Graphite body, then the instrument: an amber half-dial with an even-spend mark and three rising bars.
    NSGradient(colors: [color(0x2A2C31), color(0x141518)])!.draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let c = NSPoint(x: body.midX, y: body.minY + body.height * 0.34)
    let r = body.width * 0.33
    let lw = body.width * 0.085
    func arc(_ from: CGFloat, _ to: CGFloat, _ col: NSColor) {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: from, endAngle: to, clockwise: true)
        p.lineWidth = lw
        p.lineCapStyle = .round
        col.setStroke()
        p.stroke()
    }
    arc(180, 0, color(0x3A3D44))
    arc(180, 62, color(0xF5A524))
    // Even-spend mark across the rim.
    let a = CGFloat.pi * 40 / 180
    let tick = NSBezierPath()
    tick.move(to: NSPoint(x: c.x + (r - lw) * cos(a), y: c.y + (r - lw) * sin(a)))
    tick.line(to: NSPoint(x: c.x + (r + lw) * cos(a), y: c.y + (r + lw) * sin(a)))
    tick.lineWidth = body.width * 0.022
    tick.lineCapStyle = .round
    color(0xECEDEF).setStroke()
    tick.stroke()

    let barW = body.width * 0.07
    let gap = body.width * 0.045
    let heights: [CGFloat] = [0.11, 0.17, 0.24]
    var x = c.x - (barW * 3 + gap * 2) / 2
    for (i, h) in heights.enumerated() {
        let rect = NSRect(x: x, y: c.y - body.height * 0.02, width: barW, height: body.height * h)
        (i == 2 ? color(0xF5A524) : color(0xECEDEF)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: barW * 0.3, yRadius: barW * 0.3).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("wrote \(out)")
