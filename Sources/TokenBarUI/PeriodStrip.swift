import LocalCore
import SwiftUI

/// Plain text period row. ⌘1…⌘6 select the periods.
struct PeriodStrip: View {
    var selection: Period
    var fontSize: Double
    var palette: Palette
    var onSelect: @MainActor (Period) -> Void

    var body: some View {
        let keys: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6"]
        HStack(spacing: 0) {
            ForEach(Array(Period.allCases.enumerated()), id: \.element) { index, period in
                Button { onSelect(period) } label: {
                    Text(period.shortLabel)
                        .font(.system(size: fontSize, weight: selection == period ? .semibold : .regular))
                        .foregroundStyle(selection == period ? palette.text.color : palette.muted.color)
                        .frame(minWidth: 44, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(keys[index], modifiers: .command)
                .help("\(period.label) (⌘\(index + 1))")
                .accessibilityAddTraits(selection == period ? .isSelected : [])
                if index < Period.allCases.count - 1 { Spacer(minLength: 0) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Dönem", "Period"))
    }
}

/// Text button of the panel and the dashboard: open, close.
struct PlainAction: View {
    var title: String
    var fontSize: Double = 13
    var action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .medium))
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
