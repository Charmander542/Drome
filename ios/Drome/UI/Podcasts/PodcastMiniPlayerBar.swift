import SwiftUI

/// Mini player bar for podcasts — same chrome / layout as music `MiniPlayerBar`.
struct PodcastMiniPlayerBar: View {
    var onOpen: () -> Void

    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @EnvironmentObject private var podcastManager: PodcastManager

    var body: some View {
        if let episode = podcastPlayer.currentEpisode {
            let title = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let showName = showTitle(for: episode)

            HStack(spacing: 12) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        RemoteImage(
                            url: artworkURL(for: episode),
                            placeholderSymbol: "headphones",
                            holdImageWhileLoading: true)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(title.isEmpty ? "Episode" : title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(showName)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(episode.id)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open now playing")
                .accessibilityIdentifier("drome.podcast.mini.open")

                Button {
                    podcastPlayer.playPause()
                } label: {
                    Image(systemName: podcastPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(podcastPlayer.isPlaying ? "Pause" : "Play")

                Button {
                    podcastPlayer.skipForward(seconds: 30)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip forward 30 seconds")
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // Same Spotify-style bottom hairline as the music mini player.
                    GeometryReader { geo in
                        let filled = geo.size.width * min(max(progress, 0), 1)
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.14))
                            Rectangle()
                                .fill(Color.white.opacity(0.92))
                                .frame(width: filled)
                        }
                    }
                    .frame(height: 2)
                    .opacity(podcastPlayer.duration > 0 ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .id(episode.id)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("podcast-mini-player")
        }
    }

    private func showTitle(for episode: PodcastEpisode) -> String {
        if let show = podcastManager.subscribedShows.first(where: { $0.feedURL == episode.showID }) {
            return show.title
        }
        return "Podcast"
    }

    private func artworkURL(for episode: PodcastEpisode) -> URL? {
        if let show = podcastManager.subscribedShows.first(where: { $0.feedURL == episode.showID }) {
            return show.imageURL ?? episode.imageURL
        }
        return episode.imageURL
    }

    private var progress: CGFloat {
        let total = podcastPlayer.duration
        guard total.isFinite, total > 0 else { return 0 }
        return CGFloat(min(max(podcastPlayer.elapsed / total, 0), 1))
    }
}
