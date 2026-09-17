import SwiftUI

/// Discover and search for podcasts.
struct PodcastDiscoverView: View {
    @EnvironmentObject private var podcastManager: PodcastManager
    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var searchResults: [PodcastDiscoverResult] = []
    @State private var topPodcasts: [PodcastDiscoverResult] = []
    @State private var isSearching = false
    @State private var isLoadingSearch = false
    @State private var isLoadingTop = true
    @State private var error: String?
    @State private var subscribedFeedURLs: Set<String> = []
    @State private var searchTask: Task<Void, Never>?

    private var isQueryActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    searchSection

                    if let error {
                        errorView(error)
                    }

                    if isQueryActive {
                        searchResultsSection
                    } else if isLoadingTop {
                        ProgressView()
                            .padding(.top, 40)
                    } else if !topPodcasts.isEmpty {
                        topPodcastsSection
                    } else {
                        emptyPopular
                    }
                }
            }
            .navigationTitle("Discover Podcasts")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadTopPodcasts()
                loadSubscribedStatus()
            }
        }
    }

    // MARK: - Search

    private var searchSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search podcasts", text: $searchQuery)
                    #if !os(tvOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .onSubmit { Task { await search(immediate: true) } }
                    .onChange(of: searchQuery) { _, _ in
                        scheduleSearch()
                    }
                if isLoadingSearch {
                    ProgressView()
                        .controlSize(.small)
                } else if isQueryActive {
                    Button {
                        searchTask?.cancel()
                        searchQuery = ""
                        searchResults = []
                        isSearching = false
                        error = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(DromeColors.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Results")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            if isLoadingSearch && searchResults.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            } else if searchResults.isEmpty && isSearching && !isLoadingSearch {
                Text("No podcasts found for “\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            } else {
                ForEach(searchResults) { result in
                    discoverRow(result)
                }
            }
        }
    }

    // MARK: - Top Podcasts

    private var topPodcastsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Popular Podcasts")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            ForEach(topPodcasts) { result in
                discoverRow(result)
            }
        }
    }

    private var emptyPopular: some View {
        VStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Search for a show to get started")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: - Row

    private func discoverRow(_ result: PodcastDiscoverResult) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.show.imageURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        Image(systemName: "headphones")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(result.show.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if let author = result.show.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let category = result.show.category {
                    Text(category)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if subscribedFeedURLs.contains(result.show.feedURL) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DromeTheme.accent)
            } else {
                Button {
                    Task { await subscribe(to: result) }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(DromeTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            isLoadingSearch = false
            error = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await search(immediate: false)
        }
    }

    private func search(immediate: Bool) async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if immediate {
            searchTask?.cancel()
        }

        await MainActor.run {
            isLoadingSearch = true
            isSearching = true
            error = nil
        }

        do {
            let results = try await PodcastManager.searchPodcasts(query: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Ignore stale responses if the query changed mid-flight.
                guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                searchResults = results
                isLoadingSearch = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.error = error.localizedDescription
                searchResults = []
                isLoadingSearch = false
            }
        }
    }

    private func loadTopPodcasts() async {
        isLoadingTop = true
        do {
            topPodcasts = try await PodcastManager.topPodcasts()
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingTop = false
    }

    private func subscribe(to result: PodcastDiscoverResult) async {
        do {
            try await podcastManager.subscribe(to: result.show.feedURL)
            subscribedFeedURLs.insert(result.show.feedURL)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSubscribedStatus() {
        subscribedFeedURLs = Set(podcastManager.subscribedShows.map(\.feedURL))
    }

    private func errorView(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }
}
