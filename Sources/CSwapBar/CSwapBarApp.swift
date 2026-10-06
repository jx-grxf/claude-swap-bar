import ServiceManagement
import SwiftUI

@main
struct CSwapBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = AppState.shared

    @AppStorage("menuBarShowsUsage") private var menuBarShowsUsage = true
    @AppStorage("menuBarShowsAccount") private var menuBarShowsAccount = false

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.statusIcon)
            if let text = menuBarText {
                Text(text)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
    }

    private var menuBarText: String? {
        var parts: [String] = []
        guard let seat = store.defaultSeat else { return nil }
        if menuBarShowsAccount {
            parts.append(seat.title)
        }
        if menuBarShowsUsage, let five = store.usage[seat.id]?.fiveHour {
            parts.append("\(Int(five.currentUtilization.rounded()))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        _ = UpdateService.shared
        enableLaunchAtLoginOnce()
    }

    /// The menu bar is where the default account and the usage meters live,
    /// so start with the Mac once. Turning it off in Settings sticks.
    private func enableLaunchAtLoginOnce() {
        let key = "didEnableLaunchAtLogin"
        // Development builds run from the build folder; don't register those.
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}
