import SwiftUI

/// A compact labelled usage meter (e.g. "5h  9%  ·  resets 14:39").
struct UsageBarView: View {
    let label: String
    let window: UsageWindow

    private var fraction: Double { min(max(window.pct / 100.0, 0), 1) }

    private var tint: Color {
        switch window.pct {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .leading)

                Text("\(Int(window.pct.rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.primary)

                Spacer(minLength: 4)

                if let clock = window.clock {
                    Text("resets \(clock)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
    }
}
