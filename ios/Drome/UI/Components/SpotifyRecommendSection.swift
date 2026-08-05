import SwiftUI

/// Spotify catalog suggestions with one-tap wishlist add (companion backend).
struct SpotifyRecommendSection: View {
    let query: String

    @EnvironmentObject private var session: AppSession
    @State private var hits: [SpotifySearchHit] = []
    @State private var added = Set<String>()
    @State private var loaded = false

    var body: some View {
        Group {
            if session.wishlist == nil {
                EmptyView()
            } else if !hits.isEmpty {
                Section {
                    ForEach(hits) { hit in
                        HStack(spacing: 12) {
                            RemoteImage(url: URL(string: hit.coverUrl),
                                        placeholderSymbol: "music.note")
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title)
                                    .font(DromeTheme.rowTitle)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text([hit.artist, hit.album].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button {
                                Task { await add(hit) }
                            } label: {
                                Image(systemName: added.contains(hit.id) ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(added.contains(hit.id) ? DromeTheme.accent : .white)
                            }
                            .buttonStyle(.plain)
                            .disabled(added.contains(hit.id))
                        }
                        .listRowBackground(DromeTheme.background)
                    }
                } header: {
                    Text("Spotify recommends")
                } footer: {
                    Text("Tracks from Spotify that may not be in your library yet. Add them to your wishlist.")
                }
            }
        }
        .task(id: query) { await load() }
    }

    private func load() async {
        guard !loaded, let wishlist = session.wishlist else { return }
        loaded = true
        hits = (try? await wishlist.searchSpotify(query: query, limit: 8)) ?? []
    }

    private func add(_ hit: SpotifySearchHit) async {
        guard let wishlist = session.wishlist else { return }
        let url = hit.spotifyUrl.isEmpty
            ? "https://open.spotify.com/track/\(hit.spotifyId)"
            : hit.spotifyUrl
        do {
            _ = try await wishlist.add(spotifyLink: url)
            added.insert(hit.id)
        } catch {}
    }
}
