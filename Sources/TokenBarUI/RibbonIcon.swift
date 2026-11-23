import AppKit
import LocalCore

/// The menu-bar picture: the same ribbons, without words.
public enum RibbonIcon {
    public static func render(_ report: UsageReport, palette: Palette = .dark) -> NSImage? {
        guard !report.isEmpty else { return nil }
        let side = 20.0, scale = 2.0
        let layout = RibbonLayout(report: report, width: side, height: side, leftColumn: 3, rightColumn: 3,
                                  top: 2, bottomMargin: 2)
        guard let context = CGContext(data: nil, width: Int(side * scale), height: Int(side * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: 0, y: -side)
        var solid = palette
        solid.ribbonStart = 0.8
        solid.ribbonEnd = 1
        RibbonPainter.draw(layout, in: context, palette: solid, focus: nil, detailed: false)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }
}
