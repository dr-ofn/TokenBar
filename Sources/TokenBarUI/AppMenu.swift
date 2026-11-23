import AppKit
import LocalCore
import SwiftUI

/// The small menu of the panel and the dashboard: refresh the prices, go offline, quit.
struct AppMenu: View {
    var model: AppModel
    var palette: Palette

    var body: some View {
        Menu {
            Button(L10n.t("Fiyatları güncelle", "Update prices")) { model.updatePrices() }
                .disabled(model.isRefreshingPrices)
            Toggle(L10n.t("Çevrimdışı", "Offline"), isOn: Binding(get: { model.prefs.offline }, set: { model.setOffline($0) }))
            Divider()
            Button(L10n.t("TokenBar'dan çık", "Quit TokenBar")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(palette.muted.color)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("Fiyatları güncelle, çevrimdışı çalış, çık", "Update prices, work offline, quit"))
        .accessibilityLabel(L10n.t("Menü", "Menu"))
    }
}
