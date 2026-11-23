import LocalCore
import SwiftUI

/// When the period's tokens and dollars were used: tokens above the line, dollars below it.
/// With a focus, the whole stream dims and the focus is drawn from the line.
struct TideStrip: View {
    var report: UsageReport
    var stage: RibbonStage
    var palette: Palette
    var height: Double
    var fontSize: Double

    @State private var hoverX: Double?

    private let tickFractions = [0.0, 1.0 / 3, 2.0 / 3, 1.0]
    private let readingGap = 3.0
    private var axisHeight: Double { fontSize + 6 }
    private var readingHeight: Double { fontSize + 3 }

    var body: some View {
        GeometryReader { box in
            if let layout = TideLayout(report: report, width: box.size.width, height: height, focus: stage.focus) {
                VStack(spacing: readingGap) {
                    Text(reading(layout))
                        .font(.system(size: points(fontSize - 1)))
                        .foregroundStyle(palette.muted.color)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: readingHeight, alignment: .leading)
                    Canvas { context, _ in draw(layout, &context) }
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let p): hoverX = p.x
                            case .ended: hoverX = nil
                            }
                        }
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: readingHeight + readingGap + height + axisHeight)
    }

    /// The bucket under the pointer, or the two scales when the pointer is elsewhere.
    private func reading(_ layout: TideLayout) -> String {
        guard let hoverX else { return UsageText.tideScale(tokens: layout.peakTokens, dollars: layout.peakDollars) }
        let bucket = layout.bucket(atX: hoverX)
        return UsageText.tideHover(start: layout.start + Double(bucket) * layout.bucketSize, size: layout.bucketSize,
                                   tokens: layout.tokens[bucket], dollars: layout.dollars[bucket])
    }

    private func path(_ layout: TideLayout, outer: [Double], inner: [Double]) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: layout.xs[0], y: outer[0]))
        for s in layout.segments(outer) { p.addCurve(to: s.end, control1: s.control1, control2: s.control2) }
        p.addLine(to: CGPoint(x: layout.xs[layout.xs.count - 1], y: inner[inner.count - 1]))
        // Walk back along the inner edge: the same bucket order, drawn in reverse.
        let back = layout.segments(inner)
        for i in stride(from: back.count - 1, through: 0, by: -1) {
            let start = i > 0 ? back[i - 1].end : CGPoint(x: layout.xs[0], y: inner[0])
            p.addCurve(to: start, control1: back[i].control2, control2: back[i].control1)
        }
        p.closeSubpath()
        return p
    }

    private func fill(_ bands: [TideLayout.Band], _ layout: TideLayout, tokens: Double, dollars: Double, _ context: inout GraphicsContext) {
        for band in bands {
            let ink = palette.ink(band.harness).color
            context.fill(path(layout, outer: band.tokenOuter, inner: band.tokenInner), with: .color(ink.opacity(tokens)))
            context.fill(path(layout, outer: band.dollarOuter, inner: band.dollarInner), with: .color(ink.opacity(dollars)))
        }
    }

    private func draw(_ layout: TideLayout, _ context: inout GraphicsContext) {
        let dim = layout.focused.isEmpty ? 1.0 : 0.26
        fill(layout.bands, layout, tokens: 0.55 * dim, dollars: 0.95 * dim, &context)
        fill(layout.focused, layout, tokens: 0.7, dollars: 1, &context)
        context.fill(Path(CGRect(x: 0, y: layout.midline - 0.25, width: layout.width, height: 0.5)), with: .color(palette.muted.color.opacity(0.4)))
        axis(layout, &context)
        if let hoverX { pointer(layout, atX: hoverX, &context) }
    }

    /// Four moments under the stream; the last one is now.
    private func axis(_ layout: TideLayout, _ context: inout GraphicsContext) {
        let y = height + axisHeight / 2
        for (index, fraction) in tickFractions.enumerated() {
            let last = index == tickFractions.count - 1
            // Same reading as the hover: the first bucket sits at x = 0 and the last at the right edge.
            let time = layout.start + fraction * layout.bucketSize * Double(layout.xs.count - 1)
            let words = last ? UsageText.now : UsageText.tideTick(time: time, period: report.period)
            let anchor: UnitPoint = index == 0 ? .leading : last ? .trailing : .center
            context.draw(Text(words).font(.system(size: points(fontSize - 1.5))).foregroundColor(palette.muted.color).monospacedDigit(),
                         at: CGPoint(x: fraction * layout.width, y: y), anchor: anchor)
        }
    }

    private func pointer(_ layout: TideLayout, atX x: Double, _ context: inout GraphicsContext) {
        let at = layout.xs[layout.bucket(atX: x)]
        context.fill(Path(CGRect(x: at - 0.25, y: 0, width: 0.5, height: height)), with: .color(palette.text.color.opacity(0.6)))
    }
}

/// Names the four shades inside a ribbon.
struct StrandLegend: View {
    var harness: HarnessID?
    var palette: Palette
    var fontSize: Double

    var body: some View {
        HStack(spacing: 10) {
            ForEach(TokenKind.allCases, id: \.self) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(palette.strandColor(kind, harness: harness))
                        .frame(width: 9, height: 9)
                    Text(UsageText.kindName(kind))
                }
            }
        }
        .font(.system(size: points(fontSize)))
        .foregroundStyle(palette.muted.color)
    }
}
