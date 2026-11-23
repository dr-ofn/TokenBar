import LocalCore
import SwiftUI

/// Calls, price date and missing prices. Clicking opens how the total was counted.
struct TotalLine: View {
    var report: UsageReport
    var stage: RibbonStage
    var palette: Palette
    var fontSize: Double

    var body: some View {
        Button { stage.toggle(.total) } label: {
            Text(UsageText.totalLine(report))
                .font(.system(size: fontSize))
                .foregroundStyle(palette.muted.color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("Dönemin tam dökümü ve maliyetin nasıl hesaplandığı", "The period's full breakdown and how the cost was counted"))
    }
}

/// How to read the picture, what the pointer is on, or what went wrong. A ribbon under the
/// pointer has its own note there.
struct Caption: View {
    var report: UsageReport
    var stage: RibbonStage
    var notice: String?
    /// A neutral note (what "update prices" did); a notice outranks it.
    var info: String?
    var palette: Palette
    var fontSize: Double

    private var hovered: UsageSelection? {
        if case .flow = stage.hovered { return nil }
        return stage.hovered
    }

    var body: some View {
        Text(hovered.map { UsageText.hover($0, report) } ?? notice ?? info ?? UsageText.reading)
            .font(.system(size: fontSize))
            .lineSpacing(1)
            .foregroundStyle(hovered == nil && notice != nil ? palette.warning.color : palette.muted.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Detected: 5 tools". Clicking opens the list.
struct DetectedLine: View {
    var count: Int
    var stage: RibbonStage
    var palette: Palette
    var fontSize: Double

    var body: some View {
        Button { stage.toggleDetected() } label: {
            HStack(spacing: 4) {
                Text(DetectedTools.summary(count))
                Image(systemName: stage.showsDetected ? "chevron.down" : "chevron.right")
                    .font(.system(size: fontSize - 3, weight: .semibold))
            }
            .font(.system(size: fontSize))
            .foregroundStyle(palette.muted.color)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(DetectedTools.help)
        .accessibilityLabel(DetectedTools.summary(count))
    }
}

/// The tools found on this Mac: what each has logged, or why there is nothing to show.
struct DetectedView: View {
    var tools: [DetectedTool]
    var palette: Palette
    var fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DetectedTools.title + " (\(tools.count))")
                .font(.system(size: fontSize + 1, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tools) { tool in
                    HStack(spacing: 8) {
                        Circle().fill(palette.ink(tool.harness).color).frame(width: 8, height: 8)
                        (Text(tool.harness.name).fontWeight(.medium) + Text(" · " + tool.status).foregroundColor(palette.muted.color))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: fontSize))
                    .frame(minHeight: 24)
                    .accessibilityElement(children: .combine)
                }
            }
            Text(DetectedTools.footnote)
                .font(.system(size: fontSize - 1))
                .foregroundStyle(palette.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
