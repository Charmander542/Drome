import SwiftUI

/// Horizontal rail for recently played albums, playlists, mixes, and songs.
/// Cards mirror the source they came from and resume the saved shuffle /
/// queue / playhead when possible.
struct HorizontalRecentRail: View {
    let title: String
    let entries: [RecentPlayEntry]
    var dailyMixes: [DailyMix] = []

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var rotation: RotationManager
    @Environment(\.songNavigator) private var songNavigator

    @State private var spinningVibe: MoodVibe?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(DromeTheme.headlineFont)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(entries) { entry in
                        card(for: entry)
                            .frame(width: 148, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func card(for entry: RecentPlayEntry) -> some View {
        switch entry {
        case .song(let song):
            Button {
                resumeOrPlaySong(song)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    RemoteImage(url: session.artworkURL(id: song.coverArt ?? song.albumId ?? song.id, size: 300))
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    HStack(spacing: 4) {
                        Text(song.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        RatingBadge(rating: ratings.rating(for: song), size: 10)
                    }
                    SongArtistLinks(song: song, font: .caption, color: DromeTheme.muted,
                                    navigatesOnTap: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        case .album(let id, let name, let coverSong):
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: session.artworkURL(
                    id: coverSong.coverArt ?? coverSong.albumId ?? id, size: 300))
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                SongArtistLinks(song: coverSong, font: .caption, color: DromeTheme.muted,
                                navigatesOnTap: false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                songNavigator?.viewAlbum(Album(
                    id: id, name: name, artist: coverSong.artist, artistId: coverSong.artistId,
                    coverArt: coverSong.coverArt, songCount: nil, duration: nil, playCount: nil,
                    created: nil, year: nil, genre: nil, userRating: nil))
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("View album \(name)")
            .hoverEffectDisabled()

        case .playlist(let id, let name, let coverSong):
            Button {
                resumeOrPlayPlaylist(id: id, name: name, coverSong: coverSong)
            } label: {
                coverCard(
                    coverID: id,
                    title: name,
                    subtitle: "Playlist",
                    badge: nil
                )
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        case .mix(_, let name, let coverSong, let subtitle):
            mixCard(name: name, coverSong: coverSong, subtitle: subtitle)
        }
    }

    @ViewBuilder
    private func mixCard(name: String, coverSong: Song, subtitle: String) -> some View {
        if let vibe = MoodVibe.allCases.first(where: {
            $0.title == name || ($0 == .lucky && name.localizedCaseInsensitiveContains("lucky"))
        }) {
            Button {
                if player.resumeSession(forKey: "mix:\(name)") { return }
                Task {
                    spinningVibe = vibe
                    await MoodPlayer.play(vibe, session: session)
                    spinningVibe = nil
                }
            } label: {
                // Square tile — not the circular dial chip used on the tuner.
                MoodVibeTile(vibe: vibe, isSpinning: spinningVibe == vibe)
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
            .disabled(spinningVibe != nil)

        } else if let mix = dailyMixes.first(where: { $0.title == name }) {
            // Same as the Daily Mixes rail: open the mix (collage cover), don't autoplay.
            NavigationLink {
                DailyMixDetailView(mix: mix)
            } label: {
                DailyMixCard(mix: mix)
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        } else if name.hasPrefix("Daily Mix") || subtitle == "Daily Mix" {
            NavigationLink {
                DailyMixDetailView(title: name)
            } label: {
                dailyMixFallbackCard(title: name, subtitle: "Daily Mix")
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        } else if let collection = RatedCollection.allCases.first(where: { $0.rawValue == name }) {
            Button {
                if player.resumeSession(forKey: "mix:\(name)") { return }
                Task { await playRatedCollection(collection) }
            } label: {
                ratedFolderCard(collection)
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        } else if subtitle == "Genre" {
            Button {
                if player.resumeSession(forKey: "genre:\(name)") { return }
                Task { await playGenre(name) }
            } label: {
                coverCard(
                    coverID: coverSong.coverArt ?? coverSong.albumId ?? coverSong.id,
                    title: name,
                    subtitle: "Genre",
                    badge: nil
                )
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        } else if subtitle == "Artist", let artistId = coverSong.artistId {
            Button {
                if player.resumeSession(forKey: "artist:\(artistId)") { return }
                Task { await playArtist(id: artistId, name: name) }
            } label: {
                coverCard(
                    coverID: coverSong.coverArt ?? coverSong.artistId ?? coverSong.id,
                    title: name,
                    subtitle: "Artist",
                    badge: nil
                )
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        } else if name == RotationManager.playlistName || subtitle == "Playlist",
                  let playlistID = rotation.playlist?.id {
            Button {
                if player.resumeSession(forKey: "outOfRotation") { return }
                if player.resumeSession(forKey: "playlist:\(playlistID)") { return }
                Task { await playPlaylist(id: playlistID, name: name) }
            } label: {
                coverCard(
                    coverID: rotation.playlist?.coverArt ?? playlistID,
                    title: name,
                    subtitle: "Playlist",
                    badge: nil
                )
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        } else {
            Button {
                _ = player.resumeSession(forKey: "mix:\(name)")
            } label: {
                coverCard(
                    coverID: coverSong.coverArt ?? coverSong.albumId ?? coverSong.id,
                    title: name,
                    subtitle: subtitle,
                    badge: nil
                )
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
        }
    }

    private func resumeOrPlaySong(_ song: Song) {
        if player.resumeSession(forKey: "song:\(song.id)") { return }
        if let albumId = song.albumId, player.resumeSession(forKey: "album:\(albumId)") { return }
        player.play([song], startAt: 0,
                    context: PlaybackContext(label: song.title, kind: .search))
    }

    private func resumeOrPlayPlaylist(id: String, name: String, coverSong: Song) {
        if player.resumeSession(forKey: "playlist:\(id)") { return }
        Task { await playPlaylist(id: id, name: name, startSongId: coverSong.id) }
    }

    private func playPlaylist(id: String, name: String, startSongId: String? = nil) async {
        guard let playlist = try? await session.client.playlist(id: id),
              !playlist.songs.isEmpty else { return }
        LibraryDetailCache.store(playlist: playlist)
        let start = startSongId.flatMap { sid in playlist.songs.firstIndex(where: { $0.id == sid }) } ?? 0
        let kind: PlaybackContext.Kind = playlist.name == RotationManager.playlistName
            ? .outOfRotation
            : .playlist(id: id)
        player.play(playlist.songs, startAt: start,
                    context: PlaybackContext(label: name, kind: kind))
    }

    private func playArtist(id: String, name: String) async {
        let songs = (try? await session.client.topSongs(artistName: name, count: 40)) ?? []
        guard !songs.isEmpty else { return }
        player.play(songs, startAt: 0,
                    context: PlaybackContext(label: name, kind: .artist(id: id)))
    }

    private func playGenre(_ name: String) async {
        let songs = (try? await session.client.songsByGenre(name, count: 200)) ?? []
        guard !songs.isEmpty else { return }
        player.play(songs, startAt: 0,
                    context: PlaybackContext(label: name, kind: .genre))
    }

    private func playRatedCollection(_ collection: RatedCollection) async {
        let minRating: Int
        switch collection {
        case .fiveStars: minRating = 5
        case .fourPlus: minRating = 4
        case .topAlbums: minRating = 4
        }
        var songs = ratings.cachedSongs(minRating: minRating)
        if songs.isEmpty {
            await ratings.discoverFromServer()
            songs = ratings.cachedSongs(minRating: minRating)
        }
        guard !songs.isEmpty else { return }
        player.play(songs, startAt: 0,
                    context: PlaybackContext(label: collection.rawValue, kind: .mix))
    }

    /// Matches Daily Mix collage language without using the last-played song art.
    private func dailyMixFallbackCard(title: String, subtitle: String) -> some View {
        let indexDigit = title.split(separator: " ").last.flatMap { Int($0) } ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "#2A9D8F").opacity(0.55),
                                Color(hex: "#1D3557").opacity(0.9)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                    )
                VStack {
                    Spacer()
                    HStack {
                        Text("\(indexDigit)")
                            .font(.system(size: 42, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
    }

    /// Matches the Rated library folder tiles (icon plate, not a song cover + badge).
    private func ratedFolderCard(_ collection: RatedCollection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(collection.accent.opacity(0.22))
                Image(systemName: collection.systemImage)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(collection.accent)
            }
            .aspectRatio(1, contentMode: .fit)

            Text(collection.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(collection.subtitle)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func coverCard(coverID: String, title: String, subtitle: String, badge: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: session.artworkURL(id: coverID, size: 300))
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let badge, badge > 0 {
                    RatingBadge(rating: badge, size: 10)
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
