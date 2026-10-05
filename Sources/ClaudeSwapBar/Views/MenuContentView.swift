import SeatKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var store: AppState
    @State private var showAddSheet = false
    @State private var pendingRemoval: SeatInfo?
    @State private var updates = UpdateService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !store.isShellIntegrationInstalled {
                shellBanner
                Divider()
            }
            accountList
            if let error = store.errorMessage {
                Divider()
                errorBanner(error)
            }
            Divider()
            footer
        }
        .frame(width: 440)
        .task {
            store.reload()
            await store.refreshUsage()
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet()
                .environmentObject(store)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarIcon.appLogo)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Swap")
                    .font(.headline)
                Text(store.defaultSeat.map { "New sessions: \($0.email ?? $0.title)" } ?? "No default account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            headerButton("plus", help: "Add Account") { showAddSheet = true }
            headerButton("arrow.clockwise", help: "Refresh usage") {
                Task { await store.refreshUsage(force: true) }
            }
            .disabled(store.isRefreshingUsage)
            headerButton("gearshape", help: "Settings") {
                SettingsWindowController.show()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Shell integration banner

    private var shellBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Let plain `claude` follow the default")
                    .font(.caption.weight(.semibold))
                Text("Installs the `cseat` command and one line in ~/.zshrc.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install") {
                store.installShellIntegration()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - Account list

    private var accountList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                ForEach(store.seats) { info in
                    AccountRowView(
                        info: info,
                        isDefault: info.id == store.defaultSlug,
                        usage: store.usage[info.id],
                        problem: store.usageProblems[info.id],
                        duplicateOf: store.duplicate(of: info)?.title,
                        onMakeDefault: { store.makeDefault(info) },
                        onOpen: { store.openSession(info) },
                        onLogIn: { store.logIn(info.seat) },
                        onReveal: { store.revealInFinder(info) },
                        onRemove: { pendingRemoval = info }
                    )
                }
                if store.seats.count < 2 {
                    addHint
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(
            "Remove \(pendingRemoval?.email ?? pendingRemoval?.title ?? "account")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { info in
            Button("Remove", role: .destructive) { store.remove(info) }
        } message: { _ in
            Text("Deletes this account's folder and login. Shared memory, settings and skills stay.")
        }
    }

    private var addHint: some View {
        Button {
            showAddSheet = true
        } label: {
            Label("Add another Claude account", systemImage: "plus.circle")
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderless)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let action = store.lastAction {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(action)
                    Spacer()
                    Text("running sessions keep their account")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }

            HStack(spacing: 8) {
                Button {
                    store.makeBestDefault()
                } label: {
                    Label("Best Quota", systemImage: "wand.and.stars")
                }
                .help("Use the account with the most 5h headroom for new sessions")
                .disabled(store.seats.filter(\.isLoggedIn).count < 2)

                Spacer()

                if store.isRefreshingUsage {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    updates.checkForUpdates()
                } label: {
                    Image(systemName: updates.isUpdateAvailable
                        ? "arrow.down.circle.fill"
                        : "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(updates.isUpdateAvailable ? Color.accentColor : Color.primary)
                .help(updates.isUpdateAvailable
                    ? "Install Available Update"
                    : "Check for Updates")
                .accessibilityLabel(updates.isUpdateAvailable
                    ? "Update available"
                    : "Check for Updates")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit Claude Swap Bar")
                .accessibilityLabel("Quit")
            }
            .font(.caption)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
