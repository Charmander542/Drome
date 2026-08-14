import SwiftUI

/// Horizontal rail of recently played *tracks* (not albums).
struct HorizontalSongRail: View {
    let title: String
    let songs: [Song]

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var ratings: RatingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(DromeTheme.headlineFont)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        songCard(song, index: index)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func songCard(_ song: Song, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: session.client.coverArtURL(
                id: song.coverArt ?? song.albumId ?? song.id, size: 300))
                .frame(width: 148, height: 148)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 4) {
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                RatingBadge(rating: ratings.rating(for: song), size: 10)
            }
            SongArtistLinks(song: song, font: .caption, color: DromeTheme.muted)
        }
        .frame(width: 148, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            player.play(songs, startAt: index,
                        context: PlaybackContext(label: song.title, kind: .search))
        }
        .hoverEffectDisabled()
    }
}
