import SwiftUI

/// tvOS Podcasts home — shows subscriptions and in-progress episodes.
struct TVPodcastsView: View {
    @EnvironmentObject private var podcastManager: PodcastManager
    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @EnvironmentObject private var session: AppSession

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 42) {
                TVScreenTitle(title: "Podcasts", subtitle: "Your shows and episodes")
                    .padding(.horizontal, TVTheme.gutter)
                    .padding(.top, 12)

                let inProgress = podcastManager.inProgressEpisodes()
                if !inProgress.isEmpty {
                    TVRail(title: "Continue Listening", items: inProgress) { item in
                        TVPodcastPosterButton(
                            title: item.episode.title,
                            subtitle: item.episode.durationText,
                            imageURL: item.episode.imageURL)
                        {
                            podcastPlayer.play(item.episode, resumeFromSaved: true)
                        }
                    }
                }

                if !podcastManager.subscribedShows.isEmpty {
                    TVRail(title: "Your Shows", items: podcastManager.subscribedShows) { show in
                        NavigationLink {
                            TVPodcastShowView(show: show)
                                .environmentObject(podcastManager)
                                .environmentObject(podcastPlayer)
                        } label: {
                            TVPodcastPoster(
                                title: show.title,
                                subtitle: show.author,
                                imageURL: show.imageURL)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    TVEmptyState(title: "No Podcasts Yet", subtitle: "Search for podcasts to get started")
                }
            }
            .padding(.bottom, 60)
        }
        .background(TVTheme.canvas.ignoresSafeArea())
    }
}

/// tvOS Podcast Show Detail — lists episodes for a show.
struct TVPodcastShowView: View {
    let show: PodcastShow
    @EnvironmentObject private var podcastManager: PodcastManager
    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @State private var episodes: [PodcastEpisode] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 42) {
                HStack(spacing: 24) {
                    TVPodcastArt(url: show.imageURL, size: 160)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(show.title)
                            .font(.title.bold())
                        if let author = show.author {
                            Text(author)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        if let description = show.description {
                            Text(description)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, TVTheme.gutter)

                if isLoading {
                    ProgressView()
                        .padding(.top, 40)
                } else if !episodes.isEmpty {
                    TVRail(title: "Episodes", items: episodes) { episode in
                        TVPodcastPosterButton(
                            title: episode.title,
                            subtitle: episode.durationText,
                            imageURL: episode.imageURL ?? show.imageURL)
                        {
                            podcastPlayer.play(episode, resumeFromSaved: true)
                        }
                    }
                } else {
                    TVEmptyState(title: "No Episodes", subtitle: "Check back later for new episodes")
                }
            }
            .padding(.bottom, 60)
        }
        .background(TVTheme.canvas.ignoresSafeArea())
        .task {
            await loadEpisodes()
        }
    }

    private func loadEpisodes() async {
        isLoading = true
        episodes = (try? podcastManager.episodes(for: show.feedURL)) ?? []
        isLoading = false
    }
}

/// Direct-URL poster for podcast artwork (not Navidrome cover-art IDs).
struct TVPodcastPosterButton: View {
    let title: String
    var subtitle: String? = nil
    var imageURL: URL?
    var size: CGFloat = TVTheme.poster
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: action) {
                TVPodcastArt(url: imageURL, size: size)
            }
            TVPosterCaption(title: title, subtitle: subtitle, width: size)
        }
        .frame(width: size, alignment: .leading)
        .padding(.horizontal, TVTheme.posterPad)
    }
}

struct TVPodcastPoster: View {
    let title: String
    var subtitle: String? = nil
    var imageURL: URL?
    var size: CGFloat = TVTheme.poster

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TVPodcastArt(url: imageURL, size: size)
            TVPosterCaption(title: title, subtitle: subtitle, width: size)
        }
        .frame(width: size, alignment: .leading)
        .padding(.horizontal, TVTheme.posterPad)
    }
}

struct TVPodcastArt: View {
    let url: URL?
    var size: CGFloat = TVTheme.poster

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.3))
                    Image(systemName: "headphones")
                        .font(.system(size: size * 0.28))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// tvOS Empty State
struct TVEmptyState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
