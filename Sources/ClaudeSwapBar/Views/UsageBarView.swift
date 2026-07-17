import SwiftUI

/// A compact labelled usage meter (e.g. "5h ▓▓▓░ 9% · resets in 2h 10m").
struct UsageBarView: View {
    let label: String
    let window: UsageWindow

    private var tint: Color {
        switch window.utilization {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 24, alignment: .leading)
                .fixedSize()

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(4, geo.size.width * window.fraction))
                }
            }
            .frame(height: 6)

            Text("\(Int(window.utilization.rounded()))%")
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)

            if let reset = window.resetText {
                Text(reset)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .trailing)
            }
        }
    }
}
