import SwiftUI

struct AccountRowView: View {
    let account: Account
    let isActive: Bool
    let usage: UsageSnapshot?
    let problem: UsageProblem?
    let isBusy: Bool
    let onSwitch: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: { if !isActive && !isBusy { onSwitch() } }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    avatar

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(account.email)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let plan = account.planLabel {
                                Text(plan)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        if let org = account.organizationName {
                            Text(org)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 6)

                    trailing
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
                .strokeBorder(isActive ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .contextMenu {
            if !isActive {
                Button("Switch to this account", action: onSwitch)
            }
            Button("Remove from Claude Swap", role: .destructive, action: onRemove)
        }
    }

    private var rowBackground: Color {
        if isActive { return Color.accentColor.opacity(0.10) }
        return Color.primary.opacity(isHovering ? 0.07 : 0.035)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.22))
            Text(String(account.displayName.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private var trailing: some View {
        if isActive {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Active")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        } else if isHovering {
            Text("Switch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
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
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                    Text(usage == nil ? problem.shortText : "showing cached data — \(problem.shortText)")
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
