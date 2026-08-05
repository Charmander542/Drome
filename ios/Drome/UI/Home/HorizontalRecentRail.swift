import SwiftUI

/// Horizontal rail for recently played albums, playlists, mixes, and songs.
/// Cards mirror the source they came from (no badge overlays) and deep-link
/// back to that same place.
struct HorizontalRecentRail: View {
    let title: String
    let entries: [RecentPlayEntry]

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var rotation: RotationManager

    @State private var spinningVibe: MoodVibe?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(DromeTheme.headlineFont)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(entries) { entry in
                        card(for: entry)
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
                player.play([song], startAt: 0,
                            context: PlaybackContext(label: song.title, kind: .search))
            } label: {
                coverCard(
                    coverID: song.coverArt ?? song.albumId ?? song.id,
                    title: song.title,
                    subtitle: song.displayArtist,
                    badge: ratings.rating(for: song)
                )
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        case .album(let id, let name, let coverSong):
            NavigationLink {
                AlbumDetailView(albumID: id, placeholder: Album(
                    id: id,
                    name: name,
                    artist: coverSong.displayArtist,
                    artistId: coverSong.artistId,
                    coverArt: coverSong.coverArt,
                    songCount: nil, duration: nil, playCount: nil,
                    created: nil, year: nil, genre: nil, userRating: nil
                ))
            } label: {
                coverCard(
                    coverID: coverSong.coverArt ?? coverSong.albumId ?? id,
                    title: name,
                    subtitle: coverSong.displayArtist,
                    badge: nil
                )
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        case .playlist(let id, let name, let coverSong):
            NavigationLink {
                PlaylistDetailView(playlistID: id)
            } label: {
                coverCard(
                    coverID: coverSong.coverArt ?? coverSong.albumId ?? coverSong.id,
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
        if let vibe = MoodVibe.allCases.first(where: { $0.title == name }) {
            // Exact same vibe tile as "What's the vibe?" — tap restarts it.
            Button {
                Task {
                    spinningVibe = vibe
                    await MoodPlayer.play(vibe, session: session)
                    spinningVibe = nil
                }
            } label: {
                MoodVibeCard(vibe: vibe, isSpinning: spinningVibe == vibe)
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
            .disabled(spinningVibe != nil)

        } else if let collection = RatedCollection.allCases.first(where: { $0.rawValue == name }) {
            NavigationLink {
                RatedCollectionDetailView(collection: collection)
            } label: {
                ratedFolderCard(collection)
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        } else if subtitle == "Genre" {
            NavigationLink {
                GenreDetailView(genre: NormalizedGenre(
                    displayName: name,
                    rawTags: [name],
                    songCount: 0,
                    albumCount: 0
                ))
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
            NavigationLink {
                ArtistDetailView(artistID: artistId, placeholderName: name)
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
            NavigationLink {
                PlaylistDetailView(playlistID: playlistID)
            } label: {
                coverCard(
                    coverID: coverSong.coverArt ?? coverSong.albumId ?? coverSong.id,
                    title: name,
                    subtitle: "Playlist",
                    badge: nil
                )
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()

        } else {
            coverCard(
                coverID: coverSong.coverArt ?? coverSong.albumId ?? coverSong.id,
                title: name,
                subtitle: subtitle,
                badge: nil
            )
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
            .frame(width: 148, height: 148)

            Text(collection.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(collection.subtitle)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
        .frame(width: 148, alignment: .leading)
    }

    private func coverCard(coverID: String, title: String, subtitle: String, badge: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: session.client.coverArtURL(id: coverID, size: 300))
                .frame(width: 148, height: 148)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let badge, badge > 0 {
                    RatingBadge(rating: badge, size: 10)
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(1)
        }
        .frame(width: 148, alignment: .leading)
    }
}
