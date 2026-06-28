import SwiftUI

struct AccountRowView: View {
    let account: Account
    let isBusy: Bool
    let onSwitch: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                numberBadge

                VStack(alignment: .leading, spacing: 1) {
                    Text(account.email)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
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

            if let usage = account.usage {
                VStack(spacing: 6) {
                    if let five = usage.fiveHour {
                        UsageBarView(label: "5h", window: five)
                    }
                    if let seven = usage.sevenDay {
                        UsageBarView(label: "7d", window: seven)
                    }
                }
                .padding(.leading, 2)
            } else if account.usageStatus != "ok" {
                Text("usage unavailable")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(account.active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(isHovering ? 0.06 : 0.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(account.active ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    private var numberBadge: some View {
        ZStack {
            Circle()
                .fill(account.active ? Color.accentColor : Color.secondary.opacity(0.25))
            Text("\(account.number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(account.active ? Color.white : Color.primary)
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private var trailing: some View {
        if account.active {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("Active")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        } else if isHovering {
            Button(action: onSwitch) {
                Text("Switch")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isBusy)
        }
    }
}
