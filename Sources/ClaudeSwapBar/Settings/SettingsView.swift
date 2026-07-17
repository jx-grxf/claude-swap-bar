import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .general
    private init() {}
}

enum AppVersion {
    static let displayString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Version \(version)"
    }()
}

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared

    private var activeTab: SettingsTab {
        navigation.selectedTab ?? .general
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $navigation.selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }

                Text(AppVersion.displayString)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fontDesign(.monospaced)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch activeTab {
                case .general: GeneralSettingsPane()
                case .menuBar: MenuBarSettingsPane()
                case .about: AboutSettingsPane()
                }
            }
            .navigationTitle(activeTab.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 440)
    }
}
