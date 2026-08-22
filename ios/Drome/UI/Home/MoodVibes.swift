import SwiftUI

/// "I'm Feeling Lucky" style mood capsules for the home screen.
enum MoodVibe: String, CaseIterable, Identifiable {
    case chill
    case hype
    case lateNight
    case feelGood
    case focus
    case heartbreak
    case lucky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chill: return "Chill"
        case .hype: return "Hype"
        case .lateNight: return "Late Night"
        case .feelGood: return "Feel-Good"
        case .focus: return "Focus"
        case .heartbreak: return "Heartbreak"
        case .lucky: return "I'm Feeling Lucky"
        }
    }

    var blurb: String {
        switch self {
        case .chill: return "Soft edges, low lights"
        case .hype: return "Go full send"
        case .lateNight: return "Headphones at 1am"
        case .feelGood: return "Windows-down energy"
        case .focus: return "Get in the zone"
        case .heartbreak: return "Feel it fully"
        case .lucky: return "Surprise me"
        }
    }

    var symbol: String {
        switch self {
        case .chill: return "leaf.fill"
        case .hype: return "bolt.fill"
        case .lateNight: return "moon.stars.fill"
        case .feelGood: return "sun.max.fill"
        case .focus: return "brain.head.profile"
        case .heartbreak: return "heart.fill"
        case .lucky: return "dice.fill"
        }
    }

    /// Gradient pair for the card.
    var colors: [Color] {
        switch self {
        case .chill: return [Color(red: 0.20, green: 0.55, blue: 0.62), Color(red: 0.10, green: 0.28, blue: 0.40)]
        case .hype: return [Color(red: 0.95, green: 0.35, blue: 0.20), Color(red: 0.55, green: 0.10, blue: 0.35)]
        case .lateNight: return [Color(red: 0.25, green: 0.20, blue: 0.65), Color(red: 0.05, green: 0.05, blue: 0.18)]
        case .feelGood: return [Color(red: 0.98, green: 0.72, blue: 0.20), Color(red: 0.90, green: 0.35, blue: 0.25)]
        case .focus: return [Color(red: 0.25, green: 0.45, blue: 0.85), Color(red: 0.12, green: 0.18, blue: 0.40)]
        case .heartbreak: return [Color(red: 0.75, green: 0.18, blue: 0.35), Color(red: 0.25, green: 0.05, blue: 0.15)]
        case .lucky: return [Color(red: 0.35, green: 0.70, blue: 0.45), Color(red: 0.15, green: 0.35, blue: 0.55)]
        }
    }

    /// Genre strings to try against Navidrome (best-effort; libraries vary).
    var genreHints: [String] {
        switch self {
        case .chill: return ["Ambient", "Chillout", "Downtempo", "Lo-Fi", "LoFi", "Dream Pop", "Soft Rock"]
        case .hype: return ["Electronic", "Dance", "EDM", "Hip-Hop", "Hip Hop", "Rock", "Metal", "Punk"]
        case .lateNight: return ["Jazz", "Soul", "R&B", "RnB", "Trip-Hop", "Neo-Soul", "Blues"]
        case .feelGood: return ["Pop", "Indie", "Funk", "Disco", "Reggae", "Ska"]
        case .focus: return ["Classical", "Instrumental", "Ambient", "Soundtrack", "Post-Rock", "Minimal"]
        case .heartbreak: return ["Indie", "Folk", "Singer/Songwriter", "Alternative", "Ballad", "Sadcore"]
        case .lucky: return []
        }
    }

    /// Prefer highly rated tracks for most vibes; lucky is pure chaos.
    var minimumRatingBias: Bool {
        self != .lucky && self != .hype
    }
}

@MainActor
enum MoodPlayer {
    static func play(_ vibe: MoodVibe, session: AppSession) async {
        if let client = session.wishlist,
           let mix = try? await client.vibeMix(id: vibe.rawValue),
           !mix.songs.isEmpty {
            play(mix.songs, vibe: vibe, session: session)
            return
        }
        await playLocal(vibe, session: session)
    }

    private static func play(_ songs: [Song], vibe: MoodVibe, session: AppSession) {
        let excluded = session.rotation.excludedIDs
        let filtered = songs.filter { !excluded.contains($0.id) }.uniquedByID()
        guard !filtered.isEmpty else { return }
        session.ratings.ingest(filtered)
        session.player.play(filtered, startAt: 0,
                            context: PlaybackContext(label: vibe.title, kind: .mix))
    }

    /// Companion-offline path: same idea as Daily Mix (anchors + similar)
    /// with the vibe's genre seed instead of a taste cluster.
    private static func playLocal(_ vibe: MoodVibe, session: AppSession) async {
        let client = session.client
        let ratings = session.ratings
        let rotation = session.rotation
        let excluded = rotation.excludedIDs

        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for genre in vibe.genreHints.prefix(5) {
                group.addTask {
                    (try? await client.songsByGenre(genre, count: 40)) ?? []
                }
            }
            if vibe == .lucky {
                group.addTask {
                    (try? await client.randomSongs(size: 100)) ?? []
                }
            }
            for await batch in group {
                pool.append(contentsOf: batch)
            }
        }

        pool = pool.filter { !excluded.contains($0.id) }.uniquedByID()
        if pool.count < 20 {
            pool.append(contentsOf: (try? await client.randomSongs(size: 80)) ?? [])
            pool = pool.filter { !excluded.contains($0.id) }.uniquedByID()
        }

        ratings.ingest(pool)

        let anchors = Array(pool
            .sorted { ratings.rating(for: $0) > ratings.rating(for: $1) }
            .compactMap(\.artistId)
            .uniqued()
            .prefix(3))
        await withTaskGroup(of: [Song].self) { group in
            for id in anchors {
                group.addTask {
                    (try? await client.similarSongs(artistId: id, count: 20)) ?? []
                }
            }
            for await batch in group {
                pool.append(contentsOf: batch)
            }
        }
        pool = pool.filter { !excluded.contains($0.id) }.uniquedByID()

        if vibe.minimumRatingBias {
            let ordered = ShuffleEngine.weightedShuffle(pool) { ratings.rating(for: $0) }
            guard !ordered.isEmpty else { return }
            session.player.play(Array(ordered.prefix(50)), startAt: 0,
                                context: PlaybackContext(label: vibe.title, kind: .mix))
        } else if vibe == .hype {
            let ordered = pool.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
            let top = Array(ordered.prefix(max(40, ordered.count / 2)))
            guard !top.isEmpty else { return }
            session.player.play(top.shuffled(), startAt: 0,
                                context: PlaybackContext(label: vibe.title, kind: .mix))
        } else {
            let use = Array(pool.shuffled().prefix(50))
            guard !use.isEmpty else { return }
            session.player.play(use, startAt: 0,
                                context: PlaybackContext(label: vibe.title, kind: .mix))
        }
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
                    Text("Pick a mood — we'll roll the dice on your library.")
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(MoodVibe.allCases) { vibe in
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

/// Shared vibe tile — sized like `AlbumCard` (148pt square art + two text lines).
struct MoodVibeCard: View {
    let vibe: MoodVibe
    var isSpinning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                LinearGradient(colors: vibe.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: vibe.symbol)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isSpinning {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                } else if vibe == .lucky {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }

            Text(vibe.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(vibe.blurb)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
        .frame(width: 148)
        .hoverEffectDisabled()
        .scaleEffect(isSpinning ? 0.97 : 1)
        .animation(.easeInOut(duration: 0.15), value: isSpinning)
    }
}
