import SeatKit
import SwiftUI

struct AccountRowView: View {
    let info: SeatInfo
    let isDefault: Bool
    let usage: UsageSnapshot?
    let problem: UsageProblem?
    /// Short name of another account logged in to the same claude.ai login.
    let duplicateOf: String?
    let onMakeDefault: () -> Void
    let onOpen: () -> Void
    let onLogIn: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: { if !isDefault { onMakeDefault() } }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    avatar

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(info.email ?? info.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let plan = info.planLabel {
                                Text(plan)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 6)

                    trailing
                }

                if let duplicateOf {
                    Label("Same login as \(duplicateOf). Log in again with the right account (right-click → Log In Again).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                usageSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isDefault ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .contextMenu {
            if !isDefault {
                Button("Use for New Sessions", action: onMakeDefault)
            }
            Button("Open Claude Code with This Account", action: onOpen)
                .disabled(!info.isLoggedIn)
            Button(info.isLoggedIn ? "Log In Again…" : "Log In…", action: onLogIn)
            Divider()
            Button("Show Folder in Finder", action: onReveal)
            if !info.seat.isMain {
                Button("Remove Account…", role: .destructive, action: onRemove)
            }
        }
    }

    /// Account name, plus live sessions when any run in this account.
    private var subtitle: String {
        var parts = [info.seat.isMain ? "main · ~/.claude" : info.title]
        if info.runningSessions > 0 {
            parts.append("\(info.runningSessions) running")
        }
        return parts.joined(separator: " · ")
    }

    private var rowBackground: Color {
        if isDefault { return Color.accentColor.opacity(0.10) }
        return Color.primary.opacity(isHovering ? 0.07 : 0.035)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(isDefault ? Color.accentColor : Color.secondary.opacity(0.22))
            Text(String((info.email ?? info.title).prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isDefault ? Color.white : Color.primary)
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            if isDefault {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Default")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            } else if isHovering {
                Text("Use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            if info.isLoggedIn {
                Button(action: onOpen) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Open Claude Code with this account")
                .accessibilityLabel("Open Claude Code with \(info.email ?? info.title)")
            } else {
                Button("Log In", action: onLogIn)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let usage {
                if let five = usage.fiveHour {
                    UsageBarView(label: "5h", window: five)
                }
                if let seven = usage.sevenDay {
                    UsageBarView(label: "7d", window: seven)
                }
                ForEach(usage.scoped, id: \.name) { scoped in
                    UsageBarView(label: scoped.name, window: scoped.window)
                }
            }

            // Stale data stays visible; the note below explains why it isn't
            // updating right now.
            if let problem {
                HStack(spacing: 5) {
                    Image(systemName: problem == .idle ? "moon.zzz" : "clock.arrow.circlepath")
                        .font(.caption2)
                    Text(usage == nil || problem == .notLoggedIn ? problem.shortText : "cached — \(problem.shortText)")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            } else if usage == nil {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("loading usage…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
