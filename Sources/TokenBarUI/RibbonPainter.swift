import CoreGraphics
import LocalCore

/// Paints ribbons and rails into a context whose y grows downward.
enum RibbonPainter {
    static let rail = 5.0
    private static let dimmed = 0.16
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func outline(_ flow: some FlowShape, _ layout: RibbonLayout) -> CGPath {
        let left = layout.leftX, right = layout.rightX, middle = (left + right) / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: flow.leftTop))
        path.addCurve(to: CGPoint(x: right, y: flow.rightTop),
                      control1: CGPoint(x: middle, y: flow.leftTop), control2: CGPoint(x: middle, y: flow.rightTop))
        path.addLine(to: CGPoint(x: right, y: flow.rightTop + flow.rightHeight))
        path.addCurve(to: CGPoint(x: left, y: flow.leftTop + flow.leftHeight),
                      control1: CGPoint(x: middle, y: flow.rightTop + flow.rightHeight),
                      control2: CGPoint(x: middle, y: flow.leftTop + flow.leftHeight))
        path.closeSubpath()
        return path
    }

    private static func fill(_ flow: some FlowShape, ink: RGB, alpha: Double, _ layout: RibbonLayout, _ palette: Palette, _ context: CGContext) {
        let colors = [ink.cg(palette.ribbonStart * alpha), ink.cg(palette.ribbonEnd * alpha)] as CFArray
        guard let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 1]) else { return }
        context.saveGState()
        context.addPath(outline(flow, layout))
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: layout.leftX, y: 0), end: CGPoint(x: layout.rightX, y: 0), options: [])
        context.restoreGState()
    }

    /// The thin line along the top of a strand, separating it from the one above.
    private static func thread(_ strand: RibbonLayout.Strand, color: CGColor, _ layout: RibbonLayout, _ context: CGContext) {
        let left = layout.leftX, right = layout.rightX, middle = (left + right) / 2
        let line = CGMutablePath()
        line.move(to: CGPoint(x: left, y: strand.leftTop))
        line.addCurve(to: CGPoint(x: right, y: strand.rightTop),
                      control1: CGPoint(x: middle, y: strand.leftTop), control2: CGPoint(x: middle, y: strand.rightTop))
        context.addPath(line)
        context.setStrokeColor(color)
        context.setLineWidth(0.5)
        context.strokePath()
    }

    private static func drawStrands(_ strands: [RibbonLayout.Strand], of r: RibbonLayout.Ribbon, dim: Double,
                                    _ layout: RibbonLayout, _ palette: Palette, _ context: CGContext) {
        let visible = strands.filter { $0.leftHeight + $0.rightHeight >= 0.05 }
        for strand in visible {
            let look = palette.strand(strand.kind)
            fill(strand, ink: palette.ink(r.stat.harness, tone: r.tone, lift: look.lift), alpha: look.alpha * dim, layout, palette, context)
        }
        let line = palette.ink(r.stat.harness, tone: r.tone, lift: palette.isLight ? -0.18 : 0.18).cg(0.34 * dim)
        for strand in visible.dropFirst() { thread(strand, color: line, layout, context) }
    }

    /// `detailed` adds the rails, the token kinds inside the ribbons and the free point.
    static func draw(_ layout: RibbonLayout, in context: CGContext, palette: Palette, focus: UsageSelection?, detailed: Bool) {
        // Wide ribbons first, so a thin one crossing them stays visible.
        for r in layout.ribbons.sorted(by: { $0.leftHeight + $0.rightHeight > $1.leftHeight + $1.rightHeight }) {
            let dim = focus.map { $0.contains(r.stat) ? 1 : dimmed } ?? 1
            let ink = palette.ink(r.stat.harness, tone: r.tone)
            let strands = detailed ? r.strands : []
            if strands.isEmpty {
                fill(r, ink: ink, alpha: (detailed ? 0.85 : 1) * dim, layout, palette, context)
            } else {
                drawStrands(strands, of: r, dim: dim, layout, palette, context)
            }
            guard detailed else { continue }
            context.setFillColor(ink.cg(dim))
            context.fill(CGRect(x: layout.leftX - rail, y: r.leftTop, width: rail, height: r.leftHeight))
            context.fill(CGRect(x: layout.rightX, y: r.rightTop, width: rail, height: r.rightHeight))
        }
        guard detailed, let point = layout.freePoint else { return }
        // The halo's area follows the tokens that end here at no cost.
        let halo = 2.5 + 11 * layout.freeShare.squareRoot()
        let center = CGPoint(x: layout.rightX + 2, y: point)
        context.setFillColor(palette.muted.cg(0.24))
        context.fillEllipse(in: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2))
        context.setFillColor(palette.muted.cg())
        context.fillEllipse(in: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
    }
}
