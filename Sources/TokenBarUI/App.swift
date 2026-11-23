import AppKit
import LocalCore
import SwiftUI

public struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel()

    public init() { model.start() }

    public var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("TokenBar", id: "dashboard") {
            DashboardView(model: model)
        }
        .defaultSize(width: DashboardView.defaultSize.width, height: DashboardView.defaultSize.height)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Menu-bar label: the ribbons themselves, small. When `TOKENBAR_OPEN=dashboard` is set, the
/// dashboard window is opened as soon as the menu item is first rendered.
struct MenuLabel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let icon = model.menuIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "chart.bar.fill")
            }
        }
        .accessibilityLabel(model.report.map(UsageText.summary) ?? "TokenBar")
        .onAppear {
            if ProcessInfo.processInfo.environment["TOKENBAR_OPEN"] == "dashboard" {
                openWindow(id: "dashboard")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
