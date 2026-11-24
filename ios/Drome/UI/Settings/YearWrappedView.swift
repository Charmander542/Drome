import SwiftUI

/// Year / period retrospective built from on-device play history.
///
/// Adapted from Aura’s `WrappedView` ideas (GPL-3.0) — see NOTICE.
/// Drome stays device-only for now (no Last.fm); save tops as a playlist.
struct YearWrappedView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var period: ListeningStatsPeriod = .thisYear
    @State private var stats: ListeningStats = .empty
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var saved = false
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                periodPicker
                if isLoading {
                    ProgressView()
                        .tint(DromeTheme.accent)
                        .padding(.top, 40)
                } else if stats.isEmpty {
                    emptyState
                } else {
                    saveButton
                    statTiles
                    if !stats.topSongs.isEmpty { topSongs }
                    if !stats.topArtists.isEmpty { topArtists }
                    if !stats.topAlbums.isEmpty { topAlbums }
                    if !stats.topGenres.isEmpty { topGenres }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.black)
        .navigationTitle("Wrapped")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: period) { _, _ in
            saved = false
            reload()
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            MadeForYouCoverView(
                nature: .retrospective(period.wrappedLabel),
                cornerRadius: 24)
            .frame(width: 200, height: 200)
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)

            Text(period.title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text(stats.isEmpty ? "Your year in music" : stats.personality)
                .font(.headline)
                .foregroundStyle(DromeTheme.accent)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            Text(ListeningStatsPeriod.thisYear.title).tag(ListeningStatsPeriod.thisYear)
            Text(ListeningStatsPeriod.days30.title).tag(ListeningStatsPeriod.days30)
            Text(ListeningStatsPeriod.days7.title).tag(ListeningStatsPeriod.days7)
            Text(ListeningStatsPeriod.allTime.title).tag(ListeningStatsPeriod.allTime)
        }
        .pickerStyle(.segmented)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(DromeTheme.muted)
            Text("Your Wrapped is still being written")
                .font(DromeTheme.rowTitle)
                .foregroundStyle(.white)
            Text("Keep listening — top songs, artists, and genres for \(period.title) show up here.")
                .font(DromeTheme.captionFont)
                .foregroundStyle(DromeTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var saveButton: some View {
        Button {
            Task { await saveAsPlaylist() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(saved ? DromeTheme.accent : DromeTheme.accent.opacity(0.15))
                        .frame(width: 34, height: 34)
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: saved ? "checkmark" : "plus")
                            .font(.subheadline.bold())
                            .foregroundStyle(saved ? .white : DromeTheme.accent)
                    }
                }
                Text(saved ? "Saved to Playlists" : "Save as Playlist")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(saved ? DromeTheme.muted : .white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSaving || saved || stats.topSongs.isEmpty)
    }

    private var statTiles: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            tile("Songs Played", "\(stats.totalPlays)", "play.circle.fill")
            tile("Listening Time", hoursLabel, "clock.fill")
            tile("Unique Songs", "\(stats.uniqueSongs)", "music.note")
            tile("Artists", "\(stats.uniqueArtists)", "music.mic")
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(DromeTheme.accent)
            Text(value)
                .font(.title.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var hoursLabel: String {
        let minutes = max(0, stats.totalSeconds / 60)
        if minutes <= 0 { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60.0
        return hours < 10
            ? String(format: "%.1f hrs", hours)
            : "\(Int(hours.rounded())) hrs"
    }

    private var topSongs: some View {
        card("Top Songs", icon: "star.fill") {
            ForEach(Array(stats.topSongs.prefix(5).enumerated()), id: \.element.id) { index, entry in
                Button {
                    playSong(entry.song, in: stats.topSongs.map(\.song))
                } label: {
                    rankRow(
                        rank: index + 1,
                        title: entry.song.title,
                        subtitle: entry.song.displayArtist,
                        cover: entry.song.coverArt ?? entry.song.albumId,
                        plays: entry.playCount)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var topArtists: some View {
        card("Top Artists", icon: "music.mic") {
            ForEach(Array(stats.topArtists.prefix(5).enumerated()), id: \.element.id) { index, item in
                rankRow(
                    rank: index + 1,
                    title: item.name,
                    subtitle: nil,
                    cover: item.coverArt,
                    plays: item.playCount,
                    circle: true)
            }
        }
    }

    private var topAlbums: some View {
        card("Top Albums", icon: "square.stack.fill") {
            ForEach(Array(stats.topAlbums.prefix(5).enumerated()), id: \.element.id) { index, item in
                rankRow(
                    rank: index + 1,
                    title: item.name,
                    subtitle: item.subtitle,
                    cover: item.coverArt,
                    plays: item.playCount)
            }
        }
    }

    private var topGenres: some View {
        let maxPlays = max(stats.topGenres.first?.playCount ?? 1, 1)
        return card("Top Genres", icon: "guitars.fill") {
            ForEach(stats.topGenres) { genre in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(genre.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(genre.playCount)×")
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                    }
                    GeometryReader { geo in
                        Capsule()
                            .fill(DromeTheme.accent.opacity(0.25))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(DromeTheme.accent)
                                    .frame(
                                        width: geo.size.width
                                            * CGFloat(genre.playCount)
                                            / CGFloat(maxPlays))
                            }
                    }
                    .frame(height: 8)
                }
            }
        }
    }

    private func card<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(DromeTheme.accent)
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DromeTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func rankRow(
        rank: Int,
        title: String,
        subtitle: String?,
        cover: String?,
        plays: Int,
        circle: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(rank == 1 ? .white : DromeTheme.muted)
                .frame(width: 26, height: 26)
                .background(
                    rank == 1 ? DromeTheme.accent : DromeTheme.elevated2,
                    in: Circle())
            Group {
                if circle {
                    RemoteImage(url: session.artworkURL(id: cover, size: 96), placeholderSymbol: "person.fill")
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    RemoteImage(url: session.artworkURL(id: cover, size: 96), placeholderSymbol: "music.note")
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text("\(plays)×")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(DromeTheme.muted)
        }
    }

    private func playSong(_ song: Song, in queue: [Song]) {
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.play(
            queue,
            startAt: index,
            context: PlaybackContext(label: "Wrapped • \(period.title)", kind: .mix))
    }

    private func saveAsPlaylist() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let ids = Array(stats.topSongs.map(\.song.id).prefix(50))
        guard !ids.isEmpty else { return }
        let name = "Wrapped • \(period.title)"
        do {
            let existing = try await session.client.playlists()
            if let match = existing.first(where: { $0.name == name }) {
                try await session.client.replacePlaylist(id: match.id, name: name, songIds: ids)
            } else {
                _ = try await session.client.createPlaylist(name: name, songIds: ids)
            }
            saved = true
            statusMessage = "Saved “\(name)” to your playlists"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func reload() {
        isLoading = true
        let database = session.database
        let userKey = session.account.userKey
        let selected = period
        Task.detached(priority: .userInitiated) {
            let next = (try? database.listeningStats(
                userKey: userKey, period: selected, topLimit: 8)) ?? .empty
            await MainActor.run {
                stats = next
                isLoading = false
            }
        }
    }
}
