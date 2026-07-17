import AppKit
import SwiftUI

/// Guided add-account flow. Claude's login always happens through Claude Code
/// itself; this sheet walks through it and captures the fresh login the
/// moment it appears — no Terminal scripts, no manual refresh.
struct AddAccountSheet: View {
    @EnvironmentObject private var store: AppState
    @Environment(\.dismiss) private var dismiss

    private let loginPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: MenuBarIcon.appLogo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("Add a Claude Account")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            if let email = store.unmanagedLoginEmail {
                captureCard(email: email)
            } else {
                loginInstructions
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onReceive(loginPoll) { _ in
            // Picks up a fresh `claude /login` without any user action.
            store.reload()
        }
    }

    private func captureCard(email: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Claude Code is logged in as **\(email)** — not yet managed here.")
                    .font(.callout)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Button {
                store.addCurrentClaudeAccount()
                dismiss()
            } label: {
                Label("Add \(email)", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
    }

    private var loginInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.activeAccount != nil {
                Label {
                    Text("The current Claude Code login is already managed.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                }
            }

            Text("To add another account:")
                .font(.callout.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                instructionRow(1, "Open a terminal and run `claude /login`.")
                instructionRow(2, "Sign in with the account you want to add.")
                instructionRow(3, "This sheet detects the new login automatically — one click and it's added.")
            }

            Text("Your current account stays safely stored — switch back any time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                ProgressView()
                    .controlSize(.small)
                Text("waiting for a new login…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func instructionRow(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
