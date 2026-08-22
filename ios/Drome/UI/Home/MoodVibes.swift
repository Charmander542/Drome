import SwiftUI

/// Mood stations for the home tuner. Hype and Chill lead; the rest follow.
enum MoodVibe: String, CaseIterable, Identifiable {
    case hype
    case chill
    case feelGood
    case lateNight
    case focus
    case heartbreak
    case lucky

    var id: String { rawValue }

    static var spectrum: [MoodVibe] { allCases }

    var title: String {
        switch self {
        case .chill: return "Chill"
        case .hype: return "Hype"
        case .lateNight: return "Late Night"
        case .feelGood: return "Feel-Good"
        case .focus: return "Focus"
        case .heartbreak: return "Heartbreak"
        case .lucky: return "Lucky"
        }
    }

    var blurb: String {
        switch self {
        case .focus: return "Slow instrumentals — jazz, classical, ambient"
        case .lateNight: return "Quiet songs with words, for winding down"
        case .chill: return "Story-first and unhurried — country & folk"
        case .heartbreak: return "The sad ones, on purpose"
        case .feelGood: return "Sun coming through the windows"
        case .hype: return "High-energy hip-hop, dance, and loud"
        case .lucky: return "A random slice of the library"
        }
    }

    var shortLabel: String {
        switch self {
        case .lateNight: return "Night"
        case .feelGood: return "Happy"
        case .heartbreak: return "Hurt"
        default: return title
        }
    }

    var dialHint: String {
        switch self {
        case .focus: return "Slow · instrumental"
        case .lateNight: return "Slow · lyrics"
        case .chill: return "Country slow"
        case .heartbreak: return "Sad songs"
        case .feelGood: return "Upbeat"
        case .hype: return "High energy"
        case .lucky: return "Random"
        }
    }

    var symbol: String {
        switch self {
        case .chill: return "leaf"
        case .hype: return "bolt.fill"
        case .lateNight: return "moon.stars.fill"
        case .feelGood: return "sun.max.fill"
        case .focus: return "metronome.fill"
        case .heartbreak: return "heart.fill"
        case .lucky: return "dice.fill"
        }
    }

    /// Ink + wash — not the numbered collage language Daily Mixes use.
    var ink: Color {
        switch self {
        case .focus: return Color(red: 0.78, green: 0.74, blue: 0.62)
        case .lateNight: return Color(red: 0.62, green: 0.72, blue: 0.95)
        case .chill: return Color(red: 0.55, green: 0.78, blue: 0.52)
        case .heartbreak: return Color(red: 0.92, green: 0.42, blue: 0.48)
        case .feelGood: return Color(red: 0.98, green: 0.78, blue: 0.32)
        case .hype: return Color(red: 1.0, green: 0.42, blue: 0.22)
        case .lucky: return Color(red: 0.62, green: 0.88, blue: 0.95)
        }
    }

    var wash: Color {
        switch self {
        case .focus: return Color(red: 0.12, green: 0.11, blue: 0.09)
        case .lateNight: return Color(red: 0.07, green: 0.08, blue: 0.16)
        case .chill: return Color(red: 0.08, green: 0.12, blue: 0.08)
        case .heartbreak: return Color(red: 0.14, green: 0.06, blue: 0.08)
        case .feelGood: return Color(red: 0.16, green: 0.10, blue: 0.04)
        case .hype: return Color(red: 0.16, green: 0.05, blue: 0.04)
        case .lucky: return Color(red: 0.08, green: 0.12, blue: 0.14)
        }
    }

    /// EQ silhouette — slow vibes are sparse, hype is dense.
    var meterHeights: [CGFloat] {
        switch self {
        case .focus: return [5, 7, 6, 8, 5]
        case .lateNight: return [6, 9, 7, 10, 6]
        case .chill: return [8, 11, 9, 10, 8]
        case .heartbreak: return [5, 13, 7, 6, 9]
        case .feelGood: return [12, 15, 11, 16, 13]
        case .hype: return [16, 18, 14, 18, 16]
        case .lucky: return [9, 16, 6, 17, 10]
        }
    }
}

@MainActor
enum MoodPlayer {
    static func play(_ vibe: MoodVibe, session: AppSession) async {
        let excluded = session.rotation.excludedIDs
        let songs = await gather(vibe: vibe, session: session)
        let picked = VibeEngine.pick(vibe: vibe, from: songs, excluded: excluded)
        guard !picked.isEmpty else { return }
        session.ratings.ingest(picked)
        session.player.play(
            picked, startAt: 0,
            context: PlaybackContext(label: vibe.title, kind: .mix))
    }

    private static func gather(vibe: MoodVibe, session: AppSession) async -> [Song] {
        let client = session.client
        if vibe == .lucky {
            return (try? await client.randomSongs(size: 100)) ?? []
        }
        let tags = VibeEngine.taste(for: vibe).fetch
        var pool: [Song] = []
        // Keep this light so Navidrome still has headroom for the lossless stream.
        await withTaskGroup(of: [Song].self) { group in
            for tag in tags.prefix(3) {
                group.addTask {
                    var batch = (try? await client.randomSongs(size: 24, genre: tag)) ?? []
                    if batch.count < 10 {
                        batch += (try? await client.songsByGenre(tag, count: 24)) ?? []
                    }
                    return batch
                }
            }
            for await batch in group {
                pool.append(contentsOf: batch)
            }
        }
        if pool.count < 20 {
            pool += (try? await client.randomSongs(size: 80)) ?? []
        }
        return pool.uniquedByID()
    }
}

struct MoodVibeRail: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var spinning: MoodVibe?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's the vibe?")
                        .font(DromeTheme.headlineFont)
                    Text("Tempo and genre — not your ratings.")
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(MoodVibe.spectrum) { vibe in
                        Button {
                            Task { await start(vibe) }
                        } label: {
                            MoodVibeCard(vibe: vibe, isSpinning: spinning == vibe)
                        }
                        .buttonStyle(.plain)
                        .disabled(spinning != nil)
                    }
                }
                .padding(.horizontal, 16)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func start(_ vibe: MoodVibe) async {
        error = nil
        spinning = vibe
        defer { spinning = nil }
        await MoodPlayer.play(vibe, session: session)
        if player.current == nil {
            error = "Couldn't find tracks for that vibe — try another, or add more music."
        }
    }
}

/// Circular station chip — deliberately not a 148pt square mix tile.
struct MoodVibeCard: View {
    let vibe: MoodVibe
    var isSpinning: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(vibe.wash)
                    .overlay {
                        Circle().stroke(vibe.ink.opacity(0.35), lineWidth: 1.5)
                    }
                Circle()
                    .stroke(vibe.ink.opacity(0.18), lineWidth: 8)
                    .padding(10)
                if isSpinning {
                    ProgressView().tint(vibe.ink)
                } else {
                    Image(systemName: vibe.symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(vibe.ink)
                }
            }
            .frame(width: 88, height: 88)
            .shadow(color: vibe.ink.opacity(0.22), radius: 10, y: 4)

            VStack(spacing: 2) {
                Text(vibe.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(vibe.dialHint)
                    .font(.caption2)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }
        }
        .frame(width: 100)
        .hoverEffectDisabled()
    }
}

/// Square vibe tile for Recently Played — same footprint as album art cards.
struct MoodVibeTile: View {
    let vibe: MoodVibe
    var isSpinning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(vibe.wash)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(vibe.ink.opacity(0.35), lineWidth: 1)
                Image(systemName: vibe.symbol)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(vibe.ink)
                if isSpinning {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            Text(vibe.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(vibe.blurb)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
        .hoverEffectDisabled()
        .scaleEffect(isSpinning ? 0.97 : 1)
        .animation(.easeInOut(duration: 0.15), value: isSpinning)
    }
}
