import SwiftUI

/// Button that reveals popular Spotify tracks matching an artist/album query,
/// filtered to ones that don't already look like they're in the local library.
struct SpotifyMissingTracksSection: View {
    /// Shown on the disclosure button.
    var buttonTitle: String = "Find popular songs you don't have"
    /// Spotify search query (e.g. `artist:"Radiohead"` or `album:"OK Computer" artist:Radiohead`).
    let query: String
    /// Local tracks used to filter out songs already owned.
    let ownedSongs: [Song]

    @EnvironmentObject private var session: AppSession

    @State private var hits: [SpotifySearchHit] = []
    @State private var added = Set<String>()
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var error: String?
    @State private var isExpanded = false

    var body: some View {
        Group {
            if session.wishlist == nil {
                EmptyView()
            } else {
                Section {
                    if !isExpanded {
                        Button {
                            isExpanded = true
                            Task { await loadIfNeeded() }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "opticaldisc.fill")
                                    .font(.title3)
                                    .foregroundStyle(DromeTheme.accent)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(buttonTitle)
                                        .font(DromeTheme.rowTitle)
                                        .foregroundStyle(.white)
                                    Text("Search Spotify for popular tracks missing from your library")
                                        .font(.caption)
                                        .foregroundStyle(DromeTheme.muted)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(DromeTheme.muted)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DromeTheme.background)
                    } else if isLoading {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Checking Spotify…")
                                .foregroundStyle(DromeTheme.muted)
                        }
                        .listRowBackground(DromeTheme.background)
                    } else if let error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            Button("Try Again") {
                                didLoad = false
                                Task { await loadIfNeeded() }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DromeTheme.accent)
                        }
                        .listRowBackground(DromeTheme.background)
                    } else if hits.isEmpty {
                        Text("Nothing missing — Spotify’s top matches look like tracks you already have.")
                            .font(.subheadline)
                            .foregroundStyle(DromeTheme.muted)
                            .listRowBackground(DromeTheme.background)
                    } else {
                        ForEach(hits) { hit in
                            hitRow(hit)
                                .listRowBackground(DromeTheme.background)
                        }
                    }
                } header: {
                    if isExpanded {
                        Text("Missing from your library")
                    }
                } footer: {
                    if isExpanded && !hits.isEmpty {
                        Text("Add tracks to your wishlist to download them into Navidrome.")
                    }
                }
            }
        }
    }

    private func hitRow(_ hit: SpotifySearchHit) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: hit.coverUrl)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(white: 0.16)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(DromeTheme.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text([hit.artist, hit.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                Task { await add(hit) }
            } label: {
                if added.contains(hit.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DromeTheme.accent)
                } else {
                    Text("Add")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DromeTheme.accent)
                }
            }
            .buttonStyle(.plain)
            .disabled(added.contains(hit.id))
        }
    }

    private func loadIfNeeded() async {
        guard !didLoad, let wishlist = session.wishlist else { return }
        didLoad = true
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let raw = try await wishlist.searchSpotify(query: query, limit: 10)
            let owned = Self.ownedKeys(from: ownedSongs)
            hits = raw.filter { hit in
                hit.kind == "track" || hit.kind.isEmpty
            }.filter { hit in
                !Self.looksOwned(hit, owned: owned)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ hit: SpotifySearchHit) async {
        guard let wishlist = session.wishlist else { return }
        let url = hit.spotifyUrl.isEmpty
            ? "https://open.spotify.com/track/\(hit.spotifyId)"
            : hit.spotifyUrl
        do {
            _ = try await wishlist.add(spotifyLink: url)
            added.insert(hit.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Ownership matching

    private static func ownedKeys(from songs: [Song]) -> Set<String> {
        LibraryMatcher.ownedKeys(from: songs)
    }

    private static func looksOwned(_ hit: SpotifySearchHit, owned: Set<String>) -> Bool {
        LibraryMatcher.looksOwned(hit, owned: owned)
    }
}


/// Back-compat alias for older call sites.
typealias SpotifyRecommendSection = SpotifyMissingTracksSection
