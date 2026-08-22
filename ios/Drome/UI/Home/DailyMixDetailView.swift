import SwiftUI

/// Playlist-style detail for a companion Daily Mix — browse tracks, then Play / Shuffle.
struct DailyMixDetailView: View {
    var mix: DailyMix?
    var title: String?

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var resolved: DailyMix?
    @State private var isLoading = false
    @State private var error: String?
    @State private var visibleSongCount = ProgressiveSongReveal.initial

    private var display: DailyMix? { resolved ?? mix }

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
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DromeTheme.accent)
                    .foregroundStyle(.white)
                    .disabled(allSongs.isEmpty)

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
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

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
                        player.shuffleMode = .off
                        player.play(
                            allSongs, startAt: index,
                            context: PlaybackContext(label: mix.title, kind: .mix))
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
        .dromeMiniPlayerClearance()
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

    private func play(_ mix: DailyMix, shuffled: Bool) {
        guard !mix.songs.isEmpty else { return }
        if player.resumeSession(forKey: "mix:\(mix.title)") { return }
        if shuffled {
            player.playShuffled(mix.songs, context: PlaybackContext(label: mix.title, kind: .mix))
        } else {
            player.shuffleMode = .off
            player.play(mix.songs, startAt: 0,
                        context: PlaybackContext(label: mix.title, kind: .mix))
        }
    }

    private func loadIfNeeded() async {
        if let mix, !mix.songs.isEmpty {
            resolved = mix
            return
        }
        let want = title ?? mix?.title
        guard let want, !want.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let mixes = try await session.wishlist?.dailyMixes().mixes ?? []
            if let found = mixes.first(where: { $0.title == want || $0.id == mix?.id }) {
                resolved = found
            } else {
                error = "Couldn’t find \(want) for today."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
