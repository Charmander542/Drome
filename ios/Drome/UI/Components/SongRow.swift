import SwiftUI

struct SongRow: View {
    let song: Song
    var index: Int?
    var showAlbum: Bool = false
    var trailing: AnyView? = nil
    /// When true (default), attaches List swipe actions for queue.
    var enablesSwipeActions: Bool = true
    /// Cheaper row for huge catalogs (plain artist text, still shows cover).
    var lightweight: Bool = false
    /// Tap anywhere on the row to play. View Artist / View Album stay in the context menu.
    var playsOnTap: Bool = true
    /// Override the default single-track play (album/playlist context, search queue, etc).
    var onPlay: (() -> Void)? = nil

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var rotation: RotationManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.session) private var session

    @State private var showAddToPlaylist = false

    @Environment(\.songNavigator) private var songNavigator

    var body: some View {
        // Equatable content skips heavy row rebuilds when global stores tick
        // (play/pause, download progress, rating ingest) but this song's
        // visible state is unchanged.
        //
        // List (Search, albums, playlists) swallows nested Buttons — tap the
        // row itself so play always fires.
        EquatableSongRowContent(
            song: song,
            index: index,
            showAlbum: showAlbum,
            trailing: trailing,
            isCurrent: player.current?.song.id == song.id,
            rating: ratings.rating(for: song),
            inRotation: rotation.contains(song.id),
            isDownloaded: downloads.isDownloaded(song.id),
            coverURL: session?.artworkURL(for: song, size: 96),
            lightweight: lightweight
        )
        .equatable()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            playTapped()
        })
        .accessibilityAddTraits(playsOnTap ? .isButton : [])
        .accessibilityHint(playsOnTap ? "Plays this song" : "")
        .contextMenu { contextMenu }
        .modifier(ConditionalSongSwipe(enabled: enablesSwipeActions && !lightweight, song: song))
        .sheet(isPresented: $showAddToPlaylist) {
            if let session {
                NavigationStack {
                    AddToPlaylistView(song: song)
                        .dromeSession(session)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showAddToPlaylist = false }
                            }
                        }
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    private func playTapped() {
        guard playsOnTap else { return }
        if let onPlay {
            onPlay()
        } else {
            player.play([song], startAt: 0,
                        context: PlaybackContext(label: song.title, kind: .search))
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            player.playNext(song)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            player.addToQueue(song)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        Button {
            showAddToPlaylist = true
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        if SongNavigation.albumRoute(for: song) != nil {
            Button {
                songNavigator?.viewAlbum(for: song)
            } label: {
                Label("View Album", systemImage: "square.stack")
            }
        }
        let artistRoutes = SongNavigation.artistRoutes(for: song)
        if artistRoutes.count > 1 {
            Menu {
                ForEach(artistRoutes) { route in
                    Button(route.name) {
                        songNavigator?.viewArtist(id: route.artistId, name: route.name)
                    }
                }
            } label: {
                Label("View Artist", systemImage: "person.wave.2")
            }
        } else if let route = artistRoutes.first ?? SongNavigation.artistRoute(for: song) {
            Button {
                songNavigator?.viewArtist(id: route.artistId, name: route.name)
            } label: {
                Label("View Artist", systemImage: "person.wave.2")
            }
        }
        Button {
            SongShare.present(song: song)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Menu("Rate") {
            ForEach(0...5, id: \.self) { value in
                Button {
                    ratings.setRating(value, for: song)
                } label: {
                    if value == 0 {
                        Text("Clear rating")
                    } else {
                        Label {
                            Text("\(value) star\(value == 1 ? "" : "s")")
                        } icon: {
                            Image(systemName: "star.fill")
                                .foregroundStyle(RatingStyle.color(for: value))
                        }
                    }
                }
            }
        }
        if rotation.contains(song.id) {
            Button {
                Task { await rotation.remove(song, manual: true) }
            } label: {
                Label("Remove from Out of Rotation", systemImage: "lock.open")
            }
        } else {
            Button {
                Task { await rotation.add(song, manual: true) }
            } label: {
                Label("Add to Out of Rotation", systemImage: "lock")
            }
        }
        if downloads.isDownloaded(song.id) {
            Button(role: .destructive) {
                downloads.remove(songId: song.id)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else if downloads.isBusy(song.id) {
            Button(role: .destructive) {
                downloads.cancel(songId: song.id)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else {
            Button {
                downloads.download([song])
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
    }
}

/// Heavy row chrome — skipped via `.equatable()` when inputs are unchanged.
private struct EquatableSongRowContent: View, Equatable {
    let song: Song
    let index: Int?
    let showAlbum: Bool
    let trailing: AnyView?
    let isCurrent: Bool
    let rating: Int
    let inRotation: Bool
    let isDownloaded: Bool
    let coverURL: URL?
    let lightweight: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.song.id == rhs.song.id
            && lhs.song.title == rhs.song.title
            && lhs.song.duration == rhs.song.duration
            && lhs.song.album == rhs.song.album
            && lhs.song.displayArtist == rhs.song.displayArtist
            && lhs.index == rhs.index
            && lhs.showAlbum == rhs.showAlbum
            && lhs.isCurrent == rhs.isCurrent
            && lhs.rating == rhs.rating
            && lhs.inRotation == rhs.inRotation
            && lhs.isDownloaded == rhs.isDownloaded
            && lhs.coverURL == rhs.coverURL
            && lhs.lightweight == rhs.lightweight
            && (lhs.trailing == nil) == (rhs.trailing == nil)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let index {
                Text("\(index)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(isCurrent ? DromeTheme.accent : DromeTheme.muted)
                    .frame(width: 22, alignment: .trailing)
            } else {
                RemoteImage(url: coverURL)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(DromeTheme.rowTitle)
                        .foregroundStyle(isCurrent ? DromeTheme.accent : .white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    RatingBadge(rating: rating)
                    if inRotation {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(DromeTheme.muted)
                    }
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(DromeTheme.accent)
                    }
                }
                Text(subtitleLine)
                    .font(.subheadline)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if let trailing {
                trailing
            } else {
                Text(song.durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DromeTheme.muted)
            }
        }
    }

    private var subtitleLine: String {
        var parts: [String] = []
        let artist = song.displayArtist.trimmingCharacters(in: .whitespaces)
        if !artist.isEmpty { parts.append(artist) }
        if showAlbum, let album = song.album?.trimmingCharacters(in: .whitespaces), !album.isEmpty {
            parts.append(album)
        }
        return parts.joined(separator: " · ")
    }
}

private struct ConditionalSongSwipe: ViewModifier {
    let enabled: Bool
    let song: Song

    func body(content: Content) -> some View {
        if enabled {
            content.songSwipeActions(for: song)
        } else {
            content
        }
    }
}
