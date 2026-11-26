import SwiftUI

/// Mini player bar for podcasts — same chrome / layout as music `MiniPlayerBar`.
struct PodcastMiniPlayerBar: View {
    var onOpen: () -> Void

    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @EnvironmentObject private var podcastManager: PodcastManager
    @EnvironmentObject private var session: AppSession
    @State private var showOutput = false

    var body: some View {
        if let episode = podcastPlayer.currentEpisode {
            // Observe the clock separately so progress ticks don’t rebuild MainTabView.
            PodcastMiniPlayerChrome(
                episode: episode,
                showName: showTitle(for: episode),
                artworkURL: artworkURL(for: episode),
                isPlaying: podcastPlayer.isPlaying,
                remoteOutput: session.connect?.isRemote == true,
                hasConnect: session.connect != nil,
                onOpen: onOpen,
                onPlayPause: { podcastPlayer.playPause() },
                onSkipForward: { podcastPlayer.skipForward(seconds: 30) },
                onOutput: { showOutput = true },
                clock: podcastPlayer.clock
            )
            .sheet(isPresented: $showOutput) {
                AudioOutputSheet()
                    .environmentObject(session)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
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
}

private struct PodcastMiniPlayerChrome: View {
    let episode: PodcastEpisode
    let showName: String
    let artworkURL: URL?
    let isPlaying: Bool
    let remoteOutput: Bool
    let hasConnect: Bool
    let onOpen: () -> Void
    let onPlayPause: () -> Void
    let onSkipForward: () -> Void
    let onOutput: () -> Void
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        let title = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    RemoteImage(
                        url: artworkURL,
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

            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Button(action: onSkipForward) {
                Image(systemName: "goforward.30")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip forward 30 seconds")

            Button(action: onOutput) {
                Image(systemName: remoteOutput ? "speaker.wave.2.fill" : "hifispeaker.2.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(remoteOutput ? DromeTheme.accent : .white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasConnect ? "Connect and AirPlay" : "AirPlay")
            .accessibilityIdentifier("drome.podcast.mini.output")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)

                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !clock.isPlaying)) { context in
                    GeometryReader { geo in
                        let filled = geo.size.width * progress(at: context.date)
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.14))
                            Rectangle()
                                .fill(Color.white.opacity(0.92))
                                .frame(width: filled)
                        }
                    }
                }
                .frame(height: 2)
                .opacity(clock.duration > 0 ? 1 : 0)
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

    private func progress(at date: Date) -> CGFloat {
        let total = clock.duration
        guard total.isFinite, total > 0 else { return 0 }
        return CGFloat(min(max(clock.displayElapsed(at: date) / total, 0), 1))
    }
}
