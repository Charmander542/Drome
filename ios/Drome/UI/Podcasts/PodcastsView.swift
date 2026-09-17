import SwiftUI

/// Main Podcasts view — shows subscriptions, in-progress episodes, and discover.
struct PodcastsView: View {
    @EnvironmentObject private var podcastManager: PodcastManager
    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @State private var selectedTab = 0
    @State private var showAddFeed = false
    @State private var showDiscover = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let message = podcastPlayer.errorMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    // In Progress section
                    let inProgress = podcastManager.inProgressEpisodes()
                    if !inProgress.isEmpty {
                        inProgressSection(inProgress)
                    }

                    // Subscribed shows
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
                    Menu {
                        Button {
                            showAddFeed = true
                        } label: {
                            Label("Add Feed by URL", systemImage: "link")
                        }
                        Button {
                            showDiscover = true
                        } label: {
                            Label("Discover Podcasts", systemImage: "magnifyingglass")
                        }
                        Button {
                            Task { await podcastManager.refreshAll() }
                        } label: {
                            Label("Refresh All", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddFeed) {
                AddPodcastFeedSheet()
                    .environmentObject(podcastManager)
            }
            .sheet(isPresented: $showDiscover) {
                PodcastDiscoverView()
                    .environmentObject(podcastManager)
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
        Button {
            podcastPlayer.play(item.episode, resumeFromSaved: true)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RemoteImage(url: item.episode.imageURL, holdImageWhileLoading: true)
                        .frame(width: 148, height: 148)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    // Resume affordance — podcast convention vs music rails.
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

                // Track under art + remaining time (not a music-style overlay bar).
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
                    .frame(width: 148, alignment: .leading)

                if let show = podcastManager.subscribedShows.first(where: { $0.feedURL == item.episode.showID }) {
                    Text(show.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 148, alignment: .leading)
                }

                if let remaining = item.episode.remainingText {
                    Text(remaining)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DromeTheme.accent)
                        .lineLimit(1)
                        .frame(width: 148, alignment: .leading)
                }
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200))], spacing: 16) {
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
        }
    }

    private func showCard(_ show: PodcastShow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: show.imageURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        Image(systemName: "headphones")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(show.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let author = show.author {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No Podcasts Yet")
                .font(.title2.weight(.bold))

            Text("Add a podcast feed URL or discover new shows to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            HStack(spacing: 16) {
                Button {
                    showAddFeed = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(DromeTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }

                Button {
                    showDiscover = true
                } label: {
                    Label("Discover", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(DromeColors.secondaryButtonBackground, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 60)
    }
}

// MARK: - Add Podcast Feed Sheet

struct AddPodcastFeedSheet: View {
    @EnvironmentObject private var podcastManager: PodcastManager
    @Environment(\.dismiss) private var dismiss
    @State private var feedURL = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste RSS feed URL", text: $feedURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Feed URL")
                } footer: {
                    Text("Enter the RSS feed URL of a podcast. Most podcast hosting platforms provide this URL.")
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Podcast Feed")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await subscribe() }
                    }
                    .disabled(feedURL.isEmpty || isLoading)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
        }
    }

    private func subscribe() async {
        guard let url = URL(string: feedURL) else {
            error = "Invalid URL"
            return
        }

        isLoading = true
        error = nil

        do {
            try await podcastManager.subscribe(to: url.absoluteString)
            await MainActor.run { dismiss() }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }
}
