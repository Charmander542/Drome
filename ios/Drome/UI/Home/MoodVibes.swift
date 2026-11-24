import SwiftUI

@MainActor
enum MoodPlayer {
    /// Songs from recent vibe Plays — skipped on the next refill so Play feels new.
    private static var recentVibeSongIDs: [String] = []
    private static let recentCap = 160

    @discardableResult
    static func play(_ vibe: MoodVibe, session: AppSession) async -> Bool {
        let player = session.player
        var excluded = session.rotation.excludedIDs
        excluded.formUnion(recentVibeSongIDs)
        // Prefer not to open on the track already under the playhead.
        if let currentID = player.current?.song.id {
            excluded.insert(currentID)
        }

        var songs = await gatherPool(vibe: vibe, session: session)
        var picked = VibeEngine.pick(
            vibe: vibe, from: songs, excluded: excluded, memory: session.ratings.memory)

        // Tiny libraries: if recent exclusions emptied the pool, refill without them.
        if picked.count < 8 {
            songs = await gatherPool(vibe: vibe, session: session)
            picked = VibeEngine.pick(
                vibe: vibe,
                from: songs,
                excluded: session.rotation.excludedIDs.union(
                    player.current.map { [$0.song.id] } ?? []),
                memory: session.ratings.memory)
        }
        guard !picked.isEmpty else { return false }

        remember(picked)
        session.ratings.ingest(picked)
        // Always start the vibe — Play is a station button, not "queue for later".
        // adoptUpcomingMix left unrelated music/podcast audio running and only
        // rewrote Up Next, which felt like the tuner was broken.
        player.play(
            picked,
            startAt: 0,
            context: PlaybackContext(label: vibe.title, kind: .mix))
        return true
    }

    private static func remember(_ songs: [Song]) {
        recentVibeSongIDs.append(contentsOf: songs.map(\.id))
        if recentVibeSongIDs.count > recentCap {
            recentVibeSongIDs = Array(recentVibeSongIDs.suffix(recentCap))
        }
    }

    /// Genre-scoped candidate pool for a vibe — shared by Vibe Tuner and Made for you.
    static func gatherPool(vibe: MoodVibe, session: AppSession) async -> [Song] {
        let client = session.client
        if vibe == .lucky {
            // Two pulls so Lucky doesn't recycle the same random page.
            async let a = (try? await client.randomSongs(size: 100)) ?? []
            async let b = (try? await client.randomSongs(size: 100)) ?? []
            return (await a + b).uniquedByID()
        }

        let taste = VibeEngine.taste(for: vibe)
        let tags = await resolvedFetchTags(for: taste, client: client)
        var pool: [Song] = []

        // Genre-scoped pulls only — untagged randoms used to flood the pool and
        // made Hype/Chill/Focus sound like plain Shuffle All.
        await withTaskGroup(of: [Song].self) { group in
            for tag in tags.prefix(8) {
                group.addTask {
                    var batch = (try? await client.randomSongs(size: 50, genre: tag)) ?? []
                    if batch.count < 20 {
                        batch += (try? await client.songsByGenre(tag, count: 50)) ?? []
                    }
                    return batch
                }
            }
            for await batch in group {
                pool.append(contentsOf: batch)
            }
        }

        // Still thin? Retry remaining tags, then a last-resort untagged pull that
        // pick() will still filter by prefer/avoid.
        if pool.count < 24 {
            let more = Array(tags.dropFirst(8).prefix(6))
            await withTaskGroup(of: [Song].self) { group in
                for tag in more {
                    group.addTask {
                        var batch = (try? await client.songsByGenre(tag, count: 60)) ?? []
                        if batch.isEmpty {
                            batch = (try? await client.randomSongs(size: 40, genre: tag)) ?? []
                        }
                        return batch
                    }
                }
                for await batch in group {
                    pool.append(contentsOf: batch)
                }
            }
        }
        if pool.count < 12 {
            pool += (try? await client.randomSongs(size: 120)) ?? []
        }
        return pool.uniquedByID()
    }

    /// Prefer the library's real genre strings that map into this vibe, then
    /// fall back to the curated fetch list (Cool Jazz, Trap, …).
    private static func resolvedFetchTags(
        for taste: VibeEngine.Taste,
        client: SubsonicClient
    ) async -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            ordered.append(trimmed)
        }

        let serverGenres = (try? await client.genres()) ?? []
        let grouped = GenreNormalizer.shared.groupedGenres(serverGenres)
            .filter { taste.prefer.contains($0.displayName) }
            .sorted { $0.songCount > $1.songCount }

        for group in grouped {
            // Raw tags first — Navidrome matches getSongsByGenre / getRandomSongs
            // on the exact library string, not the curated display name.
            for raw in group.rawTags {
                append(raw)
            }
            append(group.displayName)
        }

        for tag in taste.fetch {
            append(tag)
        }
        return ordered
    }
}

struct MoodVibeRail: View {
    @EnvironmentObject private var session: AppSession

    @State private var spinning: MoodVibe?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's the vibe?")
                        .font(DromeTheme.headlineFont)
                    Text("The mood stays put. Songs lean toward what you play.")
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
        let ok = await MoodPlayer.play(vibe, session: session)
        if !ok {
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
                    ProgressView()
                        .controlSize(.large)
                        .tint(vibe.ink)
                } else {
                    Image(systemName: vibe.symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(vibe.ink)
                }
            }
            .frame(width: 88, height: 88)
            .shadow(color: vibe.ink.opacity(0.22), radius: 10, y: 4)

            VStack(spacing: 2) {
                Text(isSpinning ? "Mixing…" : vibe.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(isSpinning ? "Building mix" : vibe.dialHint)
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
                    ZStack {
                        Color.black.opacity(0.35)
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Mixing…")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .aspectRatio(1, contentMode: .fit)

            Text(isSpinning ? "Building mix" : vibe.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(isSpinning ? "Starting mix…" : vibe.blurb)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
        .hoverEffectDisabled()
        .scaleEffect(isSpinning ? 0.97 : 1)
        .animation(.easeInOut(duration: 0.15), value: isSpinning)
    }
}
