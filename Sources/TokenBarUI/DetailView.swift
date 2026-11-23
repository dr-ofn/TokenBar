import LocalCore
import SwiftUI

/// Exact tokens of what was clicked, how they split by kind, the parts inside it, its price and source.
struct DetailView: View {
    var detail: UsageDetail
    var stage: RibbonStage
    var palette: Palette
    var fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title)
                .font(.system(size: fontSize + 1, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let counts = detail.counts, let parts = detail.parts, counts.total > 0 {
                KindAnatomy(counts: counts, parts: parts, harness: detail.harness, palette: palette, fontSize: fontSize)
            }
            if !detail.rows.isEmpty {
                VStack(spacing: 3) {
                    ForEach(detail.rows, id: \.label) { row in
                        HStack(spacing: 8) {
                            Text(row.label).foregroundStyle(palette.muted.color)
                            Spacer(minLength: 0)
                            Text(row.value).monospacedDigit()
                        }
                        .font(.system(size: fontSize))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !detail.links.isEmpty {
                VStack(spacing: 0) {
                    ForEach(detail.links) { link($0) }
                }
            }
            if let note = detail.note {
                Text(note)
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(palette.muted.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func link(_ link: UsageDetail.Link) -> some View {
        Button { stage.selected = link.selection } label: {
            HStack(spacing: 8) {
                Text(link.title).lineLimit(1).minimumScaleFactor(0.75).layoutPriority(1)
                Spacer(minLength: 8)
                Text(UsageText.tokens(link.tokens)).monospacedDigit().fixedSize()
                Text(link.cost)
                    .monospacedDigit()
                    .foregroundStyle(palette.muted.color)
                    .fixedSize()
                    .frame(minWidth: 66, alignment: .trailing)
            }
            .font(.system(size: fontSize))
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// A ribbon opened up: how its tokens split by kind and how its dollars split by the same kinds.
private struct KindAnatomy: View {
    var counts: TokenCounts
    var parts: CostParts
    var harness: HarnessID?
    var palette: Palette
    var fontSize: Double

    var body: some View {
        VStack(spacing: 5) {
            ratioBar(L10n.t("Token", "Tokens")) { Double(counts[$0]) / Double(counts.total) }
            if parts.total > 0 {
                ratioBar(L10n.t("Dolar", "Dollars")) { parts[$0] / parts.total }
            }
            VStack(spacing: 3) {
                ForEach(TokenKind.allCases, id: \.self) { row($0) }
            }
            .padding(.top, 2)
        }
    }

    private func ratioBar(_ title: String, share: @escaping (TokenKind) -> Double) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: fontSize - 1))
                .foregroundStyle(palette.muted.color)
                .frame(width: L10n.lang == .tr ? 40 : 50, alignment: .leading)
            Canvas { context, size in
                var x = 0.0
                for kind in TokenKind.allCases {
                    let width = share(kind) * size.width
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                                 with: .color(palette.strandColor(kind, harness: harness)))
                    x += width
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .accessibilityHidden(true)
    }

    private func row(_ kind: TokenKind) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(palette.strandColor(kind, harness: harness))
                .frame(width: 9, height: 9)
            Text(UsageText.kindName(kind)).foregroundStyle(palette.muted.color)
            Spacer(minLength: 0)
            Text(UsageText.count(Int(counts[kind]))).monospacedDigit()
            Text(UsageText.percent(Double(counts[kind]), of: Double(counts.total)))
                .monospacedDigit()
                .foregroundStyle(palette.muted.color)
                .frame(width: 36, alignment: .trailing)
            Text(UsageText.money(parts[kind]))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(UsageText.percent(parts[kind], of: parts.total))
                .monospacedDigit()
                .foregroundStyle(palette.muted.color)
                .frame(width: 36, alignment: .trailing)
        }
        .font(.system(size: fontSize))
        .accessibilityElement(children: .combine)
    }
}
