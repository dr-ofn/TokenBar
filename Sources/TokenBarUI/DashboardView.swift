import LocalCore
import SwiftUI

/// The same ribbons at window size, with every harness and model listed beside them.
public struct DashboardView: View {
    public static let defaultSize = CGSize(width: 1280, height: 800)
    private static let columnWidth = 440.0

    var model: AppModel
    @State private var stage: RibbonStage
    @Environment(\.colorScheme) private var scheme

    private var palette: Palette { .current(scheme) }

    public init(model: AppModel, stage: RibbonStage = RibbonStage()) {
        self.model = model
        _stage = State(initialValue: stage)
    }

    public var body: some View {
        HStack(spacing: 0) {
            if let report = model.report {
                VStack(spacing: 8) {
                    RibbonView(report: report, stage: stage, palette: palette, fontSize: 14, leftColumn: 124, rightColumn: 232)
                    if !report.isEmpty {
                        StrandLegend(harness: report.harnesses.max { $0.cost < $1.cost }?.harness, palette: palette, fontSize: 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                        TideStrip(report: report, stage: stage, palette: palette, height: 72, fontSize: 13)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    }
                }
                .padding(.top, 20)
                column(report)
            } else {
                Text(model.notice ?? L10n.t("Araç kayıtları taranıyor…", "Scanning tool logs…"))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.muted.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(palette.background.color)
        .foregroundStyle(palette.text.color)
        .ignoresSafeArea()
    }

    private func column(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PeriodStrip(selection: report.period, fontSize: 14, palette: palette, onSelect: model.setWindow)
            HStack(spacing: 8) {
                TotalLine(report: report, stage: stage, palette: palette, fontSize: 13)
                AppMenu(model: model, palette: palette)
            }
            if !model.detectedTools.isEmpty {
                DetectedLine(count: model.detectedTools.count, stage: stage, palette: palette, fontSize: 12)
            }
            ScrollView {
                if let selected = stage.selected {
                    DetailView(detail: report.detail(selected), stage: stage, palette: palette, fontSize: 14)
                } else if stage.showsDetected {
                    DetectedView(tools: model.detectedTools, palette: palette, fontSize: 14)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(report.harnesses) { harness($0) }
                        if !report.groups.isEmpty {
                            Text(L10n.t("Modeller, dolara göre", "Models, by dollars"))
                                .font(.system(size: 12))
                                .foregroundStyle(palette.muted.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                        }
                        ForEach(report.groups.sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }) { group($0) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Caption(report: report, stage: stage, notice: model.notice, info: model.priceInfo, palette: palette, fontSize: 12)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            if stage.hasOpenPanel {
                PlainAction(title: L10n.t("Kapat", "Close"), fontSize: 14) { stage.closePanel() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: Self.columnWidth)
    }

    /// Tokens, the rate really paid and the money, in fixed columns.
    private func numbers(tokens: Int64, money: String, usd: Double) -> some View {
        Group {
            Text(UsageText.compact(tokens)).monospacedDigit().fixedSize()
            Text(UsageText.perMillion(usd, tokens: tokens))
                .monospacedDigit()
                .foregroundStyle(palette.muted.color)
                .fixedSize()
                .frame(width: 70, alignment: .trailing)
            Text(money)
                .monospacedDigit()
                .foregroundStyle(palette.muted.color)
                .fixedSize()
                .frame(width: 78, alignment: .trailing)
        }
    }

    @ViewBuilder private func harness(_ h: HarnessStat) -> some View {
        let open = stage.expanded == h.harness
        Button { stage.toggleExpanded(h.harness) } label: {
            HStack(spacing: 6) {
                Circle().fill(palette.ink(h.harness).color).frame(width: 8, height: 8)
                Text(h.harness.name).fontWeight(.medium)
                Spacer(minLength: 8)
                numbers(tokens: h.tokens, money: UsageText.money(h.cost), usd: h.cost)
            }
            .font(.system(size: 14))
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? L10n.t("Modelleri kapat", "Hide the models") : L10n.t("Modelleri aç", "Show the models"))
        .accessibilityElement(children: .combine)
        if open {
            VStack(alignment: .leading, spacing: 0) {
                Text(UsageText.line(h))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 3)
                let routes = Set(h.models.map(\.info.provider)).count
                ForEach(h.models) { row($0, namesProvider: routes > 1) }
            }
            .padding(.leading, 16)
            .padding(.bottom, 6)
        }
    }

    private func group(_ g: ModelGroup) -> some View {
        Button { stage.toggle(.model(g.key)) } label: {
            HStack(spacing: 6) {
                Circle().fill(palette.ink(g.mainHarness).color).frame(width: 8, height: 8)
                Text(g.name).lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
                Spacer(minLength: 8)
                numbers(tokens: g.tokens, money: UsageText.groupCost(g), usd: g.cost)
            }
            .font(.system(size: 13))
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("Hangi araçta ne kadar kullanıldığı ve fiyat kaynağı", "Usage per tool and the price source"))
        .accessibilityElement(children: .combine)
    }

    /// A harness that reaches every model the same way has no route worth naming on each row.
    private func row(_ m: ModelStat, namesProvider: Bool) -> some View {
        Button { stage.toggle(.flow(m.id)) } label: {
            HStack(spacing: 6) {
                (Text(m.info.name) + Text(namesProvider ? " " + m.info.provider : "").foregroundColor(palette.muted.color))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                numbers(tokens: m.tokens, money: UsageText.cost(m.cost, m.info.price), usd: m.cost)
            }
            .font(.system(size: 13))
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("Döküm, birim fiyat ve fiyat kaynağı", "Breakdown, unit price and price source"))
        .accessibilityElement(children: .combine)
    }
}
