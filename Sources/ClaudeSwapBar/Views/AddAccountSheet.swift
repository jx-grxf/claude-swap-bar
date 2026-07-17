import AppKit
import SwiftUI

/// Guided add-account flow. Claude's login always happens through Claude Code
/// itself; this sheet walks through it and then captures the fresh login into
/// the vault with one click — no Terminal scripts.
struct AddAccountSheet: View {
    @EnvironmentObject private var store: AppState
    @Environment(\.dismiss) private var dismiss

    private var currentLogin: (email: String, alreadyAdded: Bool)? {
        guard let profile = try? ClaudeCodeBridge().currentProfileJSON() else { return nil }
        let known = store.accounts.contains {
            $0.email.caseInsensitiveCompare(profile.email) == .orderedSame
        }
        return (profile.email, known)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Add a Claude Account")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            if let login = currentLogin, !login.alreadyAdded {
                captureCard(email: login.email)
            } else {
                loginInstructions(alreadyAddedEmail: currentLogin?.email)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
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

    private func loginInstructions(alreadyAddedEmail: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let email = alreadyAddedEmail {
                Label {
                    Text("The current Claude Code login (**\(email)**) is already managed.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                }
            }

            Text("To add another account:")
                .font(.callout.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                instructionRow(1, "Open a terminal and run `claude /login` (or `/login` inside a session).")
                instructionRow(2, "Sign in with the account you want to add.")
                instructionRow(3, "Come back here — the new login is detected automatically.")
            }

            Text("Don't worry about the account you're currently using — it's safely stored and you can switch back any time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                openTerminalForLogin()
            } label: {
                Label("Open Terminal", systemImage: "terminal")
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

    private func openTerminalForLogin() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
}
