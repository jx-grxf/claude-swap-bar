import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var store: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340)
        .task { await store.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
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
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .disabled(store.isLoading || store.isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Account list

    @ViewBuilder
    private var content: some View {
        if let error = store.errorMessage {
            errorView(error)
        } else if store.accounts.isEmpty {
            emptyView
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.accounts) { account in
                        AccountRowView(account: account, isBusy: store.isBusy) {
                            Task { await store.switchTo(account) }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            if store.isLoading {
                ProgressView()
            } else {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No managed accounts")
                    .font(.subheadline)
                Text("Add one with `cswap --add-account`")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let action = store.lastAction {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(action)
                    Spacer()
                    Text("restart Claude to apply")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await store.rotate(strategy: nil) }
                } label: {
                    Label("Rotate", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isBusy || store.accounts.count < 2)

                Menu {
                    Button("Most quota left") { Task { await store.rotate(strategy: .best) } }
                    Button("Next available") { Task { await store.rotate(strategy: .nextAvailable) } }
                } label: {
                    Label("Smart", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.isBusy || store.accounts.count < 2)

                Spacer()

                if store.isBusy {
                    ProgressView().controlSize(.small)
                }

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit")
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
