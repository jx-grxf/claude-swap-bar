import AppKit
import Combine
import CSwapKit
import SwiftUI

/// Creates a new account folder and starts its browser login in a terminal.
/// The login itself always happens through Claude Code; this sheet only
/// watches for it to land.
struct AddAccountSheet: View {
    @EnvironmentObject private var store: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var createdSlug: String?

    private let loginPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var created: SeatInfo? {
        createdSlug.flatMap { slug in store.seats.first { $0.id == slug } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: MenuBarIcon.appLogo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("Add an Account")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            if let created {
                waitingCard(created)
            } else {
                form
            }

            HStack {
                Spacer()
                Button(created?.isLoggedIn == true ? "Done" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onReceive(loginPoll) { _ in
            guard createdSlug != nil, created?.isLoggedIn != true else { return }
            store.reload()
            if created?.isLoggedIn == true {
                Task { await store.refreshUsage(force: true) }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each account gets its own login and shares your settings, skills, plugins and memory with the main one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Short name") {
                TextField("work", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, value in
                        name = value.lowercased().replacingOccurrences(of: " ", with: "-")
                    }
            }
            LabeledContent("Email (optional)") {
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
            }
            Text("The short name is what you type in the terminal: `cswap \(name.isEmpty ? "work" : name)`.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                if store.addSeat(named: name, email: email.trimmingCharacters(in: .whitespaces)) {
                    createdSlug = name
                }
            } label: {
                Label("Create and Log In", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!Seat.isValidSlug(name))

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func waitingCard(_ info: SeatInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if info.isLoggedIn {
                Label {
                    Text("**\(info.title)** is logged in as **\(info.email ?? "")**.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text("Start it with `cswap \(info.title)`, or click the account to use it for new sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish the login in the browser window that just opened.")
                        .font(.callout)
                }
                Text("A terminal runs `cswap login \(info.title)`. If the browser didn't open, the terminal shows the link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open the Login Again") { store.logIn(info.seat, email: email) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill((info.isLoggedIn ? Color.green : Color.accentColor).opacity(0.08)))
    }
}
