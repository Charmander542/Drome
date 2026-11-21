import SwiftUI

/// Compact steer-your-station chips (Sonora Roadtrip DJ × Drome).
struct StationSteeringBar: View {
    @Binding var steering: StationSteering
    var compact: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StationSteering.allCases) { mode in
                    Button {
                        steering = mode
                        StationSteeringStore.current = mode
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.symbol)
                                .font(.caption2.weight(.semibold))
                            Text(mode.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(steering == mode ? Color.black : Color.white.opacity(0.75))
                        .padding(.horizontal, compact ? 10 : 12)
                        .padding(.vertical, compact ? 6 : 8)
                        .background(
                            Capsule().fill(
                                steering == mode ? DromeTheme.accent : DromeTheme.elevated2
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(steering == mode ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
