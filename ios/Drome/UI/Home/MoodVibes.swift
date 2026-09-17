import SwiftUI

@MainActor
enum MoodPlayer {
    /// Songs from recent vibe Plays — skipped on the next refill so Play feels new.
    private static var recentVibeSongIDs: [String] = []
    private static let recentCap = 160

    static func play(_ vibe: MoodVibe, session: AppSession) async {
        var excluded = session.rotation.excludedIDs
        excluded.formUnion(recentVibeSongIDs)
        if let currentID = session.player.current?.song.id {
            excluded.insert(currentID)
        }

        var songs = await gather(vibe: vibe, session: session)
        var picked = VibeEngine.pick(vibe: vibe, from: songs, excluded: excluded)

        // Tiny libraries: if recent exclusions emptied the pool, refill without them.
        if picked.count < 8 {
            songs = await gather(vibe: vibe, session: session)
            picked = VibeEngine.pick(
                vibe: vibe,
                from: songs,
                excluded: session.rotation.excludedIDs)
        }
        guard !picked.isEmpty else { return }

        remember(picked)
        session.ratings.ingest(picked)
        session.player.play(
            picked, startAt: 0,
            context: PlaybackContext(label: vibe.title, kind: .mix))
    }

    private static func remember(_ songs: [Song]) {
        recentVibeSongIDs.append(contentsOf: songs.map(\.id))
        if recentVibeSongIDs.count > recentCap {
            recentVibeSongIDs = Array(recentVibeSongIDs.suffix(recentCap))
        }
    }

    private static func gather(vibe: MoodVibe, session: AppSession) async -> [Song] {
        let client = session.client
        if vibe == .lucky {
            // Two pulls so Lucky doesn't recycle the same random page.
            async let a = (try? await client.randomSongs(size: 100)) ?? []
            async let b = (try? await client.randomSongs(size: 100)) ?? []
            return (await a + b).uniquedByID()
        }
        let tags = VibeEngine.taste(for: vibe).fetch
        var pool: [Song] = []
        // Pull across more genre tags + larger batches so each Play has a
        // wide enough pool to sample a fresh queue.
        await withTaskGroup(of: [Song].self) { group in
            for tag in tags.prefix(6) {
                group.addTask {
                    var batch = (try? await client.randomSongs(size: 40, genre: tag)) ?? []
                    if batch.count < 16 {
                        batch += (try? await client.songsByGenre(tag, count: 40)) ?? []
                    }
                    return batch
                }
            }
            // Untagged randoms widen discovery, but they pollute Focus with off-vibe tracks.
            if vibe != .focus {
                group.addTask {
                    (try? await client.randomSongs(size: 80)) ?? []
                }
            }
            for await batch in group {
                pool.append(contentsOf: batch)
            }
        }
        if pool.count < 40, vibe != .focus {
            pool += (try? await client.randomSongs(size: 120)) ?? []
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
