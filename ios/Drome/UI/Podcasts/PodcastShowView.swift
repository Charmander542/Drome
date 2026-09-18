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
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                errorView(error)
            } else {
                List {
                    Section {
                        showHeader
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    Section {
                        ForEach(episodes) { episode in
                            episodeRow(episode)
                                .listRowBackground(DromeTheme.background)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    starSwipeButton(for: episode)
                                }
                                .contextMenu {
                                    Button {
                                        toggleStar(episode)
                                    } label: {
                                        Label(
                                            episode.isStarred ? "Remove Star" : "Star Episode",
                                            systemImage: episode.isStarred ? "star.slash" : "star")
                                    }
                                    Button {
                                        podcastPlayer.play(episode, resumeFromSaved: true)
                                    } label: {
                                        Label("Play", systemImage: "play.fill")
                                    }
                                }
                        }
                    } header: {
                        Text("Episodes")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
            Text("You'll still have starred episodes, but won't get new ones.")
        }
        .task {
            await loadEpisodes()
        }
        .onChange(of: podcastManager.starsRevision) { _, _ in
            // Keep row star badges in sync if starred elsewhere.
            if let refreshed = try? podcastManager.episodes(for: show.feedURL) {
                episodes = refreshed
            }
        }
    }

    // MARK: - Show Header

    private var showHeader: some View {
        VStack(spacing: 12) {
            RemoteImage(
                url: show.imageURL,
                placeholderSymbol: "headphones",
                holdImageWhileLoading: true)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    systemImage: podcastManager.isSubscribed(feedURL: show.feedURL)
                        ? "checkmark.circle.fill" : "plus.circle.fill"
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
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if let url = show.imageURL {
                ImageLoader.shared.prefetch([url], limit: 1)
            }
        }
    }

    // MARK: - Episode Row

    private func episodeRow(_ episode: PodcastEpisode) -> some View {
        Button {
            podcastPlayer.play(episode, resumeFromSaved: true)
        } label: {
            HStack(spacing: 12) {
                RemoteImage(
                    url: show.imageURL,
                    placeholderSymbol: "headphones",
                    holdImageWhileLoading: true)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(episode.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if episode.isStarred {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(DromeTheme.accent)
                        }
                    }

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

                Spacer(minLength: 0)

                episodeTrailing(episode)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func episodeTrailing(_ episode: PodcastEpisode) -> some View {
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

    private func starSwipeButton(for episode: PodcastEpisode) -> some View {
        Button {
            toggleStar(episode)
        } label: {
            Label(
                episode.isStarred ? "Unstar" : "Star",
                systemImage: episode.isStarred ? "star.slash.fill" : "star.fill")
        }
        .tint(episode.isStarred ? DromeTheme.elevated2 : DromeTheme.accent)
    }

    private func toggleStar(_ episode: PodcastEpisode) {
        let next = podcastManager.toggleStar(episode)
        if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[idx].isStarred = next
        }
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
