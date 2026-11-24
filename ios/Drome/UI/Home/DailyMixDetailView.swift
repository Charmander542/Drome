import SwiftUI

/// Playlist-style detail for a Made for you / companion Daily Mix —
/// browse tracks, Play / Shuffle, and optionally save as a server playlist.
struct DailyMixDetailView: View {
    var mix: DailyMix?
    var title: String?

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var resolved: DailyMix?
    @State private var isLoading = false
    @State private var error: String?
    @State private var visibleSongCount = ProgressiveSongReveal.initial
    @State private var isSaving = false
    @State private var saved = false
    @State private var statusMessage: String?

    private var display: DailyMix? { resolved ?? mix }
    private var isNonstop: Bool { display?.id == "mfy.nonstop" }

    var body: some View {
        Group {
            if let display {
                content(display)
            } else if isLoading {
                LoadingStateView(message: "Loading mix…")
            } else if let error {
                ErrorStateView(message: error) { Task { await loadIfNeeded() } }
            } else {
                LoadingStateView()
            }
        }
        .navigationTitle(display?.title ?? title ?? "Daily Mix")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadIfNeeded() }
    }

    private func content(_ mix: DailyMix) -> some View {
        let allSongs = mix.songs
        let visible = Array(allSongs.prefix(visibleSongCount))

        return List {
            Section {
                header(mix)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))

                HStack(spacing: 12) {
                    Button {
                        play(mix, shuffled: false)
                    } label: {
                        Label(isNonstop ? "Start" : "Play", systemImage: isNonstop ? "infinity" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DromeTheme.accent)
                    .foregroundStyle(.white)
                    .disabled(allSongs.isEmpty)

                    if !isNonstop {
                        Button {
                            play(mix, shuffled: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .disabled(allSongs.isEmpty)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if !isNonstop {
                    Button {
                        Task { await saveAsPlaylist(mix) }
                    } label: {
                        HStack {
                            Text(saved ? "Saved to Playlists" : "Save as Playlist")
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else if saved {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DromeTheme.muted)
                            }
                        }
                        .font(DromeTheme.rowTitle)
                        .foregroundStyle(saved ? DromeTheme.muted : DromeTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(allSongs.isEmpty || isSaving || saved)
                    .listRowBackground(DromeTheme.elevated)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(Color.clear)
                }

                if !mix.subtitle.isEmpty {
                    Text(mix.subtitle)
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if allSongs.isEmpty {
                    Text("No songs in this mix yet.")
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(Color.clear)
                }

                ForEach(Array(visible.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, showAlbum: true) {
                        play(mix, shuffled: false, startAt: index)
                    }
                    .listRowBackground(DromeTheme.background)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if visibleSongCount < allSongs.count {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 8)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .onAppear {
                        ProgressiveSongReveal.expand(
                            visibleCount: &visibleSongCount, total: allSongs.count)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func header(_ mix: DailyMix) -> some View {
        VStack(spacing: 14) {
            DailyMixCard(mix: mix)
                .frame(width: 180)
                .allowsHitTesting(false)

            Text("\(mix.songs.count) songs")
                .font(.subheadline)
                .foregroundStyle(DromeTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func play(_ mix: DailyMix, shuffled: Bool, startAt: Int = 0) {
        let songs = mix.songs.filter { !session.rotation.excludedIDs.contains($0.id) }
        guard !songs.isEmpty else { return }
        if isNonstop {
            // Nonstop = endless station: seed the queue and keep Infinite Shuffle on.
            player.autoplayEnabled = true
            player.play(
                songs,
                startAt: min(startAt, songs.count - 1),
                context: PlaybackContext(label: "Nonstop", kind: .mix))
            return
        }
        if shuffled {
            player.playShuffled(songs, context: PlaybackContext(label: mix.title, kind: .mix))
        } else {
            player.play(
                songs,
                startAt: min(startAt, songs.count - 1),
                context: PlaybackContext(label: mix.title, kind: .mix))
        }
    }

    private func saveAsPlaylist(_ mix: DailyMix) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let ids = mix.songs.map(\.id)
        guard !ids.isEmpty else { return }
        let name = mix.title
        do {
            let existing = try await session.client.playlists()
            if let match = existing.first(where: { $0.name == name }) {
                try await session.client.replacePlaylist(id: match.id, name: name, songIds: ids)
            } else {
                _ = try await session.client.createPlaylist(name: name, songIds: ids)
            }
            saved = true
            statusMessage = "Saved “\(name)” to your playlists"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadIfNeeded() async {
        if let mix, !mix.songs.isEmpty {
            resolved = Self.cleaned(mix, excluded: session.rotation.excludedIDs)
            return
        }
        let want = title ?? mix?.title
        guard let want, !want.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            if session.rotation.songIDs.isEmpty {
                await session.rotation.refresh()
            }
            let exclude = Array(session.rotation.excludedIDs)
            let response = try await session.wishlist?.dailyMixes(
                excludeSongIDs: exclude,
                recencyHours: PlaybackPreferences.autoplayRecencyHours
            )
            let mixes = response?.mixes ?? []
            if let found = mixes.first(where: { $0.title == want || $0.id == mix?.id }) {
                if let cleaned = Self.cleaned(found, excluded: session.rotation.excludedIDs) {
                    resolved = cleaned
                } else {
                    error = "This mix is all Out of Rotation right now."
                }
            } else {
                error = "Couldn’t find \(want) for today."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func cleaned(_ mix: DailyMix, excluded: Set<String>) -> DailyMix? {
        guard !excluded.isEmpty else { return mix }
        let songs = mix.songs.filter { !excluded.contains($0.id) }
        guard !songs.isEmpty else { return nil }
        var copy = mix
        copy.songs = songs
        return copy
    }
}
