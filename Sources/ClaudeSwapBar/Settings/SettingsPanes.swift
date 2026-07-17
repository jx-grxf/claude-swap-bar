import ServiceManagement
import SwiftUI

struct GeneralSettingsPane: View {
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 5
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Usage") {
                Picker("Refresh usage every", selection: $refreshIntervalMinutes) {
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                .pickerStyle(.menu)

                Text("Anthropic allows roughly 30 usage checks per hour per account, so shorter intervals mostly hit the cache.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                        if let launchAtLoginError {
                            Text(launchAtLoginError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        launchAtLoginError = nil
                    } catch {
                        launchAtLoginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onChange(of: refreshIntervalMinutes) { _, _ in
            AppState.shared.restartUsageTimer()
        }
    }
}

struct MenuBarSettingsPane: View {
    @AppStorage("menuBarShowsUsage") private var menuBarShowsUsage = true
    @AppStorage("menuBarShowsAccount") private var menuBarShowsAccount = false

    var body: some View {
        Form {
            Section("Menu Bar Icon") {
                Toggle(isOn: $menuBarShowsUsage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show 5-hour usage next to the icon")
                        Text("The percentage of the active account's current 5h window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $menuBarShowsAccount) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show active account name")
                        Text("The account's short name, e.g. \u{201C}admin\u{201D}.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

struct AboutSettingsPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("App", value: "Claude Swap Bar")
                LabeledContent("Version", value: AppVersion.displayString)
            }

            Section("How switching works") {
                Text("""
                Accounts are stored in this app's own vault (tokens in the macOS \
                Keychain). Switching writes the selected account's credentials to \
                the same places Claude Code reads them from — no external tools \
                involved. A running Claude Code session picks the change up within \
                about 30 seconds, or immediately after a restart.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
