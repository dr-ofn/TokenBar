import LocalCore
import SwiftUI

/// What the panel and the dashboard show before there is a report: the scan still running, or the index that could not
/// be opened. The app has no Dock icon, so the menu with "Quit" stays on it: an error must never leave no way out.
struct NoReportView: View {
    var model: AppModel
    var palette: Palette
    var fontSize: Double
    var padding: Double

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(model.notice ?? L10n.t("Araç kayıtları taranıyor…", "Scanning tool logs…"))
                    .font(.system(size: fontSize))
                    .foregroundStyle(palette.muted.color)
                    .textSelection(.enabled)
                    .padding(padding)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack {
                Spacer(minLength: 0)
                AppMenu(model: model, palette: palette)
            }
            .padding(.horizontal, padding)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
