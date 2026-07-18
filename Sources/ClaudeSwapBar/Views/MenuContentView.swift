import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var store: AppState
    @State private var showAddSheet = false
    @State private var updates = UpdateService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let email = store.unmanagedLoginEmail {
                newLoginBanner(email)
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
                Text(store.activeAccount?.email ?? "No account active")
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

    // MARK: - New login banner (one-click add)

    private func newLoginBanner(_ email: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Claude login detected")
                    .font(.caption.weight(.semibold))
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Add") {
                store.addCurrentClaudeAccount()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - Account list

    @ViewBuilder
    private var accountList: some View {
        if store.accounts.isEmpty {
            emptyView
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(store.accounts) { account in
                        AccountRowView(
                            account: account,
                            isActive: account.id == store.activeAccountID,
                            usage: store.usage[account.id],
                            problem: store.usageProblems[account.id],
                            isBusy: store.isBusy,
                            onSwitch: { Task { await store.switchTo(account) } },
                            onRemove: { store.remove(account) }
                        )
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.appLogo)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(0.9)
            Text("No accounts yet")
                .font(.headline)
            Text("Add the Claude account you're currently logged in with.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAddSheet = true
            } label: {
                Label("Add Account", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
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
            if store.claudeRestartPending, let action = store.lastAction {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(action)
                    Spacer()
                    Text("applies in ~30 s, or restart Claude")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await store.rotate(smart: false) }
                } label: {
                    Label("Rotate", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isBusy || store.accounts.count < 2)

                Button {
                    Task { await store.rotate(smart: true) }
                } label: {
                    Label("Best Quota", systemImage: "wand.and.stars")
                }
                .help("Switch to the account with the most 5h headroom")
                .disabled(store.isBusy || store.accounts.count < 2)

                Spacer()

                if store.isBusy || store.isRefreshingUsage {
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
