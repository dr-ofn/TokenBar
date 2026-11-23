import LocalCore
import SwiftUI

/// The picture with its words. Hovering dims everything else; clicking opens the breakdown.
struct RibbonView: View {
    var report: UsageReport
    var stage: RibbonStage
    var palette: Palette
    var fontSize: Double
    var leftColumn: Double
    var rightColumn: Double

    @State private var shown: UsageReport?
    @State private var previous: UsageReport?
    @State private var progress = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func layout(_ report: UsageReport, _ size: CGSize) -> RibbonLayout {
        RibbonLayout(report: report, width: size.width, height: size.height,
                     leftColumn: leftColumn, rightColumn: rightColumn, top: fontSize * 3.4, bottomMargin: 12,
                     labelGap: fontSize + 3.5)
    }

    var body: some View {
        let current = shown ?? report
        GeometryReader { box in
            if current.isEmpty {
                Text(UsageText.empty(current.period))
                    .font(.system(size: points(fontSize + 1)))
                    .foregroundStyle(palette.muted.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                picture(current, layout(current, box.size), box.size)
            }
        }
        .onAppear { shown = report }
        .onChange(of: report.version) { show(report) }
    }

    private func picture(_ current: UsageReport, _ layout: RibbonLayout, _ size: CGSize) -> some View {
        RibbonCanvas(report: current, layout: layout, previous: previous.map { self.layout($0, size) },
                     fadesWords: previous.map { $0.period != current.period } ?? false,
                     progress: progress, stage: stage, palette: palette, fontSize: fontSize)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { track($0, layout) }
            .onTapGesture(coordinateSpace: .local) { p in
                if let hit = layout.hit(x: p.x, y: p.y) { stage.toggle(hit) } else { stage.selected = nil }
                stage.clearHover()
            }
            .overlay { HoverNote(report: current, stage: stage, palette: palette, fontSize: fontSize, bounds: size) }
            .accessibilityElement()
            .accessibilityLabel(UsageText.summary(current))
    }

    private func track(_ phase: HoverPhase, _ layout: RibbonLayout) {
        switch phase {
        case .active(let p):
            let hit = layout.hit(x: p.x, y: p.y)
            var kind: TokenKind?
            if case .flow(let id) = hit { kind = layout.strand(x: p.x, y: p.y, flowID: id) }
            if stage.hovered != hit { stage.hovered = hit }
            if stage.hoveredKind != kind { stage.hoveredKind = kind }
            stage.pointer = p
        case .ended:
            stage.clearHover()
        }
    }

    /// New numbers glide in from the old picture.
    private func show(_ new: UsageReport) {
        if let selected = stage.selected, !new.has(selected) { stage.selected = nil }
        previous = shown
        shown = new
        guard !reduceMotion else { return }
        progress = 0
        withAnimation(.easeInOut(duration: 0.35)) { progress = 1 }
    }
}

/// Draws one frame of the picture, `progress` of the way from the previous one.
private struct RibbonCanvas: View, Animatable {
    var report: UsageReport
    var layout: RibbonLayout
    var previous: RibbonLayout?
    /// A new period changes every word, so they fade in; new numbers in the same period just appear.
    var fadesWords: Bool
    var progress: Double
    var stage: RibbonStage
    var palette: Palette
    var fontSize: Double

    private let margin = 16.0

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, _ in
            let focus = stage.focus
            let drawn = previous.map { layout.morphed(from: $0, progress: progress) } ?? layout
            context.withCGContext { cg in
                RibbonPainter.draw(drawn, in: cg, palette: palette, focus: focus == .total ? nil : focus, detailed: true)
            }
            if fadesWords { context.opacity = progress }
            header(&context)
            for label in layout.leftLabels { leftLabel(label, &context, focus: focus) }
            for label in layout.rightLabels { rightLabel(label, &context, focus: focus) }
        }
    }

    private func header(_ context: inout GraphicsContext) {
        let y = fontSize * 1.5
        let tokens = Text(UsageText.tokens(report.counts.total)).fontWeight(.semibold) + Text(UsageText.tokenWord).foregroundColor(palette.muted.color)
        context.draw(tokens.font(.system(size: points(fontSize + 1))).foregroundColor(palette.text.color).monospacedDigit(),
                     at: CGPoint(x: margin, y: y), anchor: .leading)
        let money = Text(UsageText.money(report.cost)).fontWeight(.semibold) + Text(UsageText.moneyWord).foregroundColor(palette.muted.color)
        context.draw(money.font(.system(size: points(fontSize + 1))).foregroundColor(palette.text.color).monospacedDigit(),
                     at: CGPoint(x: layout.rightX + RibbonPainter.rail + 8, y: y), anchor: .leading)
    }

    private func isFaded(_ label: RibbonLayout.Label, _ focus: UsageSelection?) -> Bool {
        guard let focus, focus != .total else { return false }
        return focus != label.selection && !contains(label, focus)
    }

    /// A label stays lit when one of its ribbons is the focus.
    private func contains(_ label: RibbonLayout.Label, _ focus: UsageSelection) -> Bool {
        guard case .flow(let id) = focus, let stat = report.model(id) else { return false }
        return label.selection.contains(stat)
    }

    private func leader(from: CGPoint, to: CGPoint, _ context: inout GraphicsContext) {
        guard abs(from.y - to.y) > 1 else { return }
        var line = Path()
        line.move(to: from)
        line.addLine(to: to)
        context.stroke(line, with: .color(palette.muted.color.opacity(0.45)), lineWidth: 0.5)
    }

    private func leftLabel(_ label: RibbonLayout.Label, _ context: inout GraphicsContext, focus: UsageSelection?) {
        let edge = layout.leftX - RibbonPainter.rail
        let x = edge - 8
        leader(from: CGPoint(x: x + 2, y: label.y), to: CGPoint(x: edge, y: label.anchor), &context)
        var c = context
        if isFaded(label, focus) { c.opacity *= 0.35 }
        if label.strong {
            c.draw(Text(label.title).font(.system(size: points(fontSize), weight: .semibold)).foregroundColor(palette.text.color),
                   at: CGPoint(x: x, y: label.y - fontSize * 0.62), anchor: .trailing)
            let value = Text(label.value + " · " + (label.extra ?? ""))
            c.draw(value.font(.system(size: points(fontSize - 1.5))).foregroundColor(palette.muted.color).monospacedDigit(),
                   at: CGPoint(x: x, y: label.y + fontSize * 0.62), anchor: .trailing)
        } else {
            c.draw(Text(label.title).font(.system(size: points(fontSize - 1.5))).foregroundColor(palette.muted.color),
                   at: CGPoint(x: x, y: label.y), anchor: .trailing)
        }
    }

    private func rightLabel(_ label: RibbonLayout.Label, _ context: inout GraphicsContext, focus: UsageSelection?) {
        let edge = layout.rightX + RibbonPainter.rail
        let x = edge + 8
        leader(from: CGPoint(x: edge, y: label.anchor), to: CGPoint(x: x - 2, y: label.y), &context)
        var c = context
        if isFaded(label, focus) { c.opacity *= 0.35 }
        let ink = label.harness == nil ? palette.muted.color : palette.text.color
        let value = c.resolve(Text(label.value).font(.system(size: points(fontSize - 1))).foregroundColor(palette.muted.color).monospacedDigit())
        let unbounded = CGSize(width: CGFloat.infinity, height: .infinity)
        let right = layout.width - margin
        // A long full name gets smaller, not cut, so it stays clear of its price.
        let room = right - x - value.measure(in: unbounded).width - 6
        var size = max(1, fontSize - 0.5)
        let words = label.extra.map { label.title + " · " + $0 } ?? label.title
        var title = c.resolve(Text(words).font(.system(size: points(size))).foregroundColor(ink))
        let width = title.measure(in: unbounded).width
        if width > room {
            size = UsageText.fittedFontSize(size, room: room, width: width)
            title = c.resolve(Text(words).font(.system(size: points(size))).foregroundColor(ink))
        }
        c.draw(title, at: CGPoint(x: x, y: label.y), anchor: .leading)
        c.draw(value, at: CGPoint(x: right, y: label.y), anchor: .trailing)
    }
}
