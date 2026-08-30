import WidgetKit
import SwiftUI
import AppIntents

@main
struct DromeWidgetBundle: WidgetBundle {
    var body: some Widget {
        VibeTunerWidget()
        RecentPlaysWidget()
    }
}

struct VibeTunerWidget: Widget {
    static let kind = "VibeTunerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: VibeTunerProvider()) { entry in
            VibeTunerWidgetView(entry: entry)
        }
        .configurationDisplayName("Vibe Tuner")
        .description("Dial in a mood and play a mix from your library.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct VibeTunerEntry: TimelineEntry {
    let date: Date
    let selected: MoodVibe
}

struct VibeTunerProvider: TimelineProvider {
    func placeholder(in context: Context) -> VibeTunerEntry {
        VibeTunerEntry(date: Date(), selected: .feelGood)
    }

    func getSnapshot(in context: Context, completion: @escaping (VibeTunerEntry) -> Void) {
        completion(VibeTunerEntry(date: Date(), selected: WidgetVibeStore.selectedVibe))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VibeTunerEntry>) -> Void) {
        let now = Date()
        let selected = WidgetVibeStore.selectedVibe
        completion(Timeline(entries: [
            VibeTunerEntry(date: now, selected: selected)
        ], policy: .after(now.addingTimeInterval(3600))))
    }
}

/// Medium-only copy of the home-screen Vibe Tuner card.
struct VibeTunerWidgetView: View {
    let entry: VibeTunerEntry

    private var selected: MoodVibe { entry.selected }
    private var vibes: [MoodVibe] { MoodVibe.spectrum }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            tuner
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .containerBackground(for: .widget) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(selected.wash.opacity(0.92))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(selected.ink.opacity(0.22), lineWidth: 1)
                }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("VIBE TUNER")
                    .font(.caption2.weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(selected.ink.opacity(0.7))
                Text(selected.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(selected.blurb)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                DromeBarMark(size: 16, color: selected.ink.opacity(0.85))
                WidgetVibeMeter(heights: selected.meterHeights, color: selected.ink)
                Button(intent: WidgetPlayVibeIntent(vibeID: selected.rawValue)) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .offset(x: 0.5)
                            .frame(width: 12, height: 12)
                        Text("Play")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(selected.ink, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tuner: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let n = CGFloat(max(vibes.count, 1))
                let width = geo.size.width.isFinite ? max(0, geo.size.width) : 0
                let slot = width > 0 ? width / n : 0
                let selectedIndex = vibes.firstIndex(of: selected) ?? 0

                ZStack(alignment: .leading) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { i in
                                Rectangle()
                                    .fill(Color.white.opacity(i.isMultiple(of: 4) ? 0.28 : 0.1))
                                    .frame(width: 1, height: i.isMultiple(of: 4) ? 8 : 4)
                                if i < 23 { Spacer(minLength: 0) }
                            }
                        }
                        .padding(.horizontal, 4)
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: 2)
                    }
                    .frame(height: 12)
                    .offset(y: -18)

                    if slot > 0 {
                        Capsule()
                            .fill(selected.ink.opacity(0.18))
                            .frame(width: slot, height: 48)
                            .offset(x: slot * CGFloat(selectedIndex))

                        HStack(spacing: 0) {
                            ForEach(vibes) { vibe in
                                Button(intent: WidgetSelectVibeIntent(vibeID: vibe.rawValue)) {
                                    station(vibe)
                                }
                                .buttonStyle(.plain)
                                .frame(width: slot, height: 48)
                            }
                        }
                    }
                }
            }
            .frame(height: 48)

            HStack(spacing: 0) {
                ForEach(vibes) { vibe in
                    Text(vibe.shortLabel)
                        .font(.system(size: 8, weight: vibe == selected ? .bold : .medium))
                        .foregroundStyle(vibe == selected ? selected.ink : Color.white.opacity(0.38))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func station(_ vibe: MoodVibe) -> some View {
        let on = vibe == selected
        let selectedDiameter: CGFloat = 32
        let idleDiameter: CGFloat = 18
        return ZStack {
            Circle()
                .fill(vibe.wash)
                .overlay {
                    Circle().stroke(vibe.ink.opacity(on ? 0.9 : 0.35), lineWidth: on ? 2 : 1)
                }
                .frame(width: on ? selectedDiameter : idleDiameter, height: on ? selectedDiameter : idleDiameter)
            Image(systemName: vibe.symbol)
                .font(.system(size: on ? 13 : 8, weight: .semibold))
                .foregroundStyle(vibe.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct WidgetVibeMeter: View {
    let heights: [CGFloat]
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: h)
            }
        }
        .frame(height: 18, alignment: .bottom)
    }
}

#if DEBUG
#Preview(as: .systemMedium) {
    VibeTunerWidget()
} timeline: {
    VibeTunerEntry(date: .now, selected: .hype)
}
#endif
