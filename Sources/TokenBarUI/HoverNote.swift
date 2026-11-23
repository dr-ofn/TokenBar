import LocalCore
import SwiftUI

/// A small note beside the pointer on a ribbon: its numbers and those of the kind under the pointer.
struct HoverNote: View {
    var report: UsageReport
    var stage: RibbonStage
    var palette: Palette
    var fontSize: Double
    var bounds: CGSize

    private let width = 250.0
    private let reservedHeight = 64.0

    var body: some View {
        if let pointer = stage.pointer, case .flow(let id) = stage.hovered, let model = report.model(id) {
            VStack(alignment: .leading, spacing: 2) {
                Text(UsageText.hover(.flow(id), report))
                    .foregroundStyle(palette.text.color)
                if let kind = stage.hoveredKind {
                    Text(UsageText.kindNote(kind, of: model))
                        .foregroundStyle(palette.muted.color)
                        .monospacedDigit()
                }
            }
            .font(.system(size: fontSize - 1))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .background(palette.background.color.opacity(0.94), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.muted.color.opacity(0.3), lineWidth: 0.5))
            .offset(x: Swift.min(pointer.x + 14, bounds.width - width - 8),
                    y: pointer.y + 16 + reservedHeight > bounds.height ? pointer.y - reservedHeight - 8 : pointer.y + 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }
}
