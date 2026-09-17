import SwiftUI

/// Shows episodes for a specific podcast show.
struct PodcastShowView: View {
    let show: PodcastShow
    @EnvironmentObject private var podcastManager: PodcastManager
    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @State private var episodes: [PodcastEpisode] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var isRefreshing = false
    @State private var showUnsubscribeAlert = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Show header
                showHeader

                // Episodes list
                if isLoading {
                    ProgressView()
                        .padding(.top, 40)
                } else if let error {
                    errorView(error)
                } else {
                    episodesList
                }
            }
        }
        .navigationTitle(show.title)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
        }
        .alert("Unsubscribe?", isPresented: $showUnsubscribeAlert) {
            Button("Unsubscribe", role: .destructive) {
                try? podcastManager.unsubscribe(feedURL: show.feedURL)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll still have downloaded episodes, but won't get new ones.")
        }
        .task {
            await loadEpisodes()
        }
    }

    // MARK: - Show Header

    private var showHeader: some View {
        VStack(spacing: 12) {
            AsyncImage(url: show.imageURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        Image(systemName: "headphones")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.top, 16)

            if let author = show.author {
                Text(author)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let description = show.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
            }

            HStack(spacing: 16) {
                Label("\(show.episodeCount) episodes", systemImage: "list.bullet")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if show.explicit {
                    Label("Explicit", systemImage: "e.square.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let category = show.category {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Subscribe/Unsubscribe button
            Button {
                if podcastManager.isSubscribed(feedURL: show.feedURL) {
                    showUnsubscribeAlert = true
                } else {
                    Task {
                        try? await podcastManager.subscribe(to: show.feedURL)
                    }
                }
            } label: {
                Label(
                    podcastManager.isSubscribed(feedURL: show.feedURL) ? "Subscribed" : "Subscribe",
                    systemImage: podcastManager.isSubscribed(feedURL: show.feedURL) ? "checkmark.circle.fill" : "plus.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    podcastManager.isSubscribed(feedURL: show.feedURL)
                        ? DromeColors.secondaryButtonBackground
                        : DromeTheme.accent,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .foregroundStyle(
                    podcastManager.isSubscribed(feedURL: show.feedURL)
                        ? Color.primary
                        : Color.white
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()
        }
    }

    // MARK: - Episodes List

    private var episodesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Episodes")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ForEach(episodes) { episode in
                episodeRow(episode)
            }
        }
    }

    private func episodeRow(_ episode: PodcastEpisode) -> some View {
        Button {
            podcastPlayer.play(episode, resumeFromSaved: true)
        } label: {
            HStack(spacing: 12) {
                // Episode image
                AsyncImage(url: episode.imageURL ?? show.imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.2))
                        .overlay {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Episode info
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    if let description = episode.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if let date = episode.pubDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                        }
                        Text(episode.durationText)
                        if episode.explicit {
                            Image(systemName: "e.square.fill")
                                .font(.caption2)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                // Podcast progress: ring + remaining time (not a music %/bar).
                if episode.isFullyPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else if episode.playbackPosition > 0 {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                            Circle()
                                .trim(from: 0, to: episode.progressFraction)
                                .stroke(DromeTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "play.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .offset(x: 0.5)
                        }
                        .frame(width: 32, height: 32)

                        if let remaining = episode.remainingText {
                            Text(remaining.replacingOccurrences(of: " left", with: ""))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DromeTheme.accent)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func loadEpisodes() async {
        isLoading = true
        do {
            episodes = try podcastManager.episodes(for: show.feedURL)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func refresh() async {
        isRefreshing = true
        await podcastManager.refreshFeed(feedURL: show.feedURL)
        await loadEpisodes()
        isRefreshing = false
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await loadEpisodes() }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 40)
    }
}
