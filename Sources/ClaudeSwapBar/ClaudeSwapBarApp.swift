import SwiftUI

@main
struct ClaudeSwapBarApp: App {
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
        if menuBarShowsAccount, let account = store.activeAccount {
            parts.append(account.displayName)
        }
        if menuBarShowsUsage, let active = store.activeAccount,
           let five = store.usage[active.id]?.fiveHour {
            parts.append("\(Int(five.utilization.rounded()))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
    }
}
