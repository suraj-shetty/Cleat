import SwiftUI

@main
struct CleatApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
        } label: {
            Label("Cleat", systemImage: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Cleat Setup", id: WindowID.setup) {
            SetupView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 620, height: 620)

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    /// The icon carries the one bit of state worth seeing without opening the menu:
    /// whether anything is currently mounted read/write.
    private var menuBarSymbol: String {
        if model.volumes.contains(where: \.isMountedReadWrite) {
            return "externaldrive.fill.badge.checkmark"
        }
        if !model.report.isReady && model.report.lastRun != .distantPast {
            return "externaldrive.badge.exclamationmark"
        }
        return "externaldrive"
    }
}

enum WindowID {
    static let setup = "setup"
}
