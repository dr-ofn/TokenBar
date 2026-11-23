import AppKit
import LocalCore
import SwiftUI

/// The panel behind the menu-bar picture: the ribbons, the periods, what was clicked.
public struct PanelView: View {
    public static let fixedSize = CGSize(width: 460, height: 760)

    var model: AppModel
    @State private var stage: RibbonStage
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var palette: Palette { .current(scheme) }
    /// The detected-tools line takes a row of the footer; the breakdown gives it back so the picture keeps its height.
    private var detailHeight: Double { model.detectedTools.isEmpty ? 300 : 274 }

    public init(model: AppModel, stage: RibbonStage = RibbonStage()) {
        self.model = model
        _stage = State(initialValue: stage)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let report = model.report {
                RibbonView(report: report, stage: stage, palette: palette, fontSize: 12, leftColumn: 98, rightColumn: 206)
                tide(report)
                if let selected = stage.selected {
                    ScrollView {
                        DetailView(detail: report.detail(selected), stage: stage, palette: palette, fontSize: 12)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    .frame(height: detailHeight)
                } else if stage.showsDetected {
                    ScrollView {
                        DetectedView(tools: model.detectedTools, palette: palette, fontSize: 12)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    .frame(height: detailHeight)
                }
                footer(report)
            } else {
                NoReportView(model: model, palette: palette, fontSize: 13, padding: 18)
            }
        }
        .frame(width: Self.fixedSize.width, height: Self.fixedSize.height)
        .background(palette.background.color)
        .foregroundStyle(palette.text.color)
    }

    @ViewBuilder private func tide(_ report: UsageReport) -> some View {
        if !report.isEmpty {
            VStack(spacing: 6) {
                StrandLegend(harness: report.harnesses.max { $0.cost < $1.cost }?.harness, palette: palette, fontSize: 10.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TideStrip(report: report, stage: stage, palette: palette, height: 44, fontSize: 11.5)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
        }
    }

    private func footer(_ report: UsageReport) -> some View {
        VStack(spacing: 2) {
            PeriodStrip(selection: report.period, fontSize: 13, palette: palette, onSelect: model.setWindow)
            HStack(spacing: 14) {
                TotalLine(report: report, stage: stage, palette: palette, fontSize: 11)
                if stage.hasOpenPanel { PlainAction(title: L10n.t("Kapat", "Close")) { stage.closePanel() } }
                PlainAction(title: L10n.t("Pano", "Dashboard")) {
                    openWindow(id: "dashboard")
                    // A menu-bar app stays behind the active app unless it asks to come forward.
                    NSApp.activate()
                    // The panel floats above ordinary windows and would cover the dashboard.
                    dismiss()
                }
                .keyboardShortcut("d", modifiers: .command)
                .help(L10n.t("Panoyu aç (⌘D)", "Open the dashboard (⌘D)"))
                AppMenu(model: model, palette: palette)
            }
            if !model.detectedTools.isEmpty {
                HStack {
                    DetectedLine(count: model.detectedTools.count, stage: stage, palette: palette, fontSize: 11)
                    Spacer(minLength: 0)
                }
            }
            Caption(report: report, stage: stage, notice: model.notice, info: model.priceInfo, palette: palette, fontSize: 11)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}
