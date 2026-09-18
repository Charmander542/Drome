import SwiftUI

/// Main Podcasts view — subscriptions and in-progress episodes.
struct PodcastsView: View {
    @EnvironmentObject private var podcastManager: PodcastManager
    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let message = podcastPlayer.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                let _ = podcastManager.starsRevision
                let starred = podcastManager.starredEpisodes()
                if !starred.isEmpty {
                    starredSection(starred)
                }

                let inProgress = podcastManager.inProgressEpisodes()
                if !inProgress.isEmpty {
                    inProgressSection(inProgress)
                }

                if podcastManager.subscribedShows.isEmpty {
                    emptyState
                } else {
                    subscriptionsSection
                }
            }
        }
        .navigationTitle("Podcasts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || podcastManager.subscribedShows.isEmpty)
                .accessibilityLabel("Refresh podcasts")
            }
        }
        .onAppear {
            // Warm ImageLoader so show → episode list art is instant.
            ImageLoader.shared.prefetch(
                podcastManager.subscribedShows.compactMap(\.imageURL),
                limit: 40)
        }
    }

    private func refreshAll() async {
        isRefreshing = true
        await podcastManager.refreshAll()
        isRefreshing = false
    }

    // MARK: - Starred

    private func starredSection(_ episodes: [PodcastStore.StarredEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Starred")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(episodes) { item in
                        starredCard(item)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func starredCard(_ item: PodcastStore.StarredEpisode) -> some View {
        let show = podcastManager.subscribedShows.first(where: { $0.feedURL == item.episode.showID })
        let artURL = show?.imageURL ?? item.episode.imageURL

        return Button {
            podcastPlayer.play(item.episode, resumeFromSaved: true)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(
                        url: artURL,
                        placeholderSymbol: "headphones",
                        holdImageWhileLoading: true)
                        .frame(width: 148, height: 148)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Image(systemName: "star.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(6)
                        .background(DromeTheme.accent, in: Circle())
                        .padding(8)
                }
                .frame(width: 148, height: 148)

                Text(item.episode.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(width: 148, height: 32, alignment: .topLeading)

                Text(show?.title ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 148, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                _ = podcastManager.toggleStar(item.episode)
            } label: {
                Label("Remove Star", systemImage: "star.slash")
            }
        }
    }

    // MARK: - In Progress

    private func inProgressSection(_ episodes: [PodcastStore.InProgressEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In Progress")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(episodes) { item in
                        inProgressCard(item)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func inProgressCard(_ item: PodcastStore.InProgressEpisode) -> some View {
        let show = podcastManager.subscribedShows.first(where: { $0.feedURL == item.episode.showID })
        // Prefer show art — already cached from the subscriptions grid.
        let artURL = show?.imageURL ?? item.episode.imageURL

        return Button {
            podcastPlayer.play(item.episode, resumeFromSaved: true)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RemoteImage(
                        url: artURL,
                        placeholderSymbol: "headphones",
                        holdImageWhileLoading: true)
                        .frame(width: 148, height: 148)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        }
                }
                .frame(width: 148, height: 148)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(DromeTheme.accent)
                            .frame(width: max(4, geo.size.width * item.episode.progressFraction))
                    }
                }
                .frame(width: 148, height: 4)

                Text(item.episode.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(width: 148, height: 32, alignment: .topLeading)

                Text(show?.title ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 148, alignment: .leading)

                Text(item.episode.remainingText ?? " ")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.episode.remainingText == nil ? .clear : DromeTheme.accent)
                    .lineLimit(1)
                    .frame(width: 148, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subscriptions

    private var subscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Shows")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                ],
                spacing: 16
            ) {
                ForEach(podcastManager.subscribedShows) { show in
                    NavigationLink {
                        PodcastShowView(show: show)
                            .environmentObject(podcastManager)
                            .environmentObject(podcastPlayer)
                    } label: {
                        showCard(show)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func showCard(_ show: PodcastShow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(
                url: show.imageURL,
                placeholderSymbol: "headphones",
                holdImageWhileLoading: true)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(show.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(show.author?.isEmpty == false ? (show.author ?? "") : " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(show.author?.isEmpty == false ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No Podcasts Yet")
                .font(.title2.weight(.bold))

            Text("Use Search → Podcasts to find shows or paste an RSS feed URL.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 60)
    }
}
