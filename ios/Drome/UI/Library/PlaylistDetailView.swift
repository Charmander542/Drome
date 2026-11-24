import SwiftUI
import PhotosUI
import UIKit

struct PlaylistDetailView: View {
    let playlistID: String
    var placeholder: Playlist?
    var onDeleted: (() -> Void)? = nil
    /// When embedded as a Library tab (e.g. Out of Rotation), match the
    /// library's inline title chrome instead of a large playlist title.
    var prefersInlineTitle: Bool = false

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var rotation: RotationManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var playlist: PlaylistWithSongs?
    @State private var error: String?
    @State private var isLoading = true
    @State private var isEditing = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var showAddSongs = false
    @State private var showMoreSheet = false
    @State private var showBulkOORConfirm = false
    @State private var showDuplicatesConfirm = false
    @State private var statusMessage: String?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var isUploadingCover = false
    @State private var coverBump: TimeInterval = 0
    /// Rows painted so far — full `playlist.songs` stays available for Play/Shuffle.
    @State private var visibleSongCount = ProgressiveSongReveal.initial
    @State private var suggestions: [PlaylistSongSuggester.Suggestion] = []
    @State private var suggestionsLoading = false
    @State private var suggestionsError: String?
    @State private var addingSuggestionIDs: Set<String> = []
    @State private var suggestionRefreshToken = 0

    private var isSystem: Bool {
        guard let playlist else {
            return placeholder.map { rotation.isSystemPlaylist($0) } ?? false
        }
        return playlist.name == RotationManager.playlistName
    }

    private var isFullyDownloaded: Bool {
        guard let playlist, !playlist.songs.isEmpty else { return false }
        return downloads.isPlaylistFullyDownloaded(songIds: playlist.songs.map(\.id))
    }

    private var contextKind: PlaybackContext.Kind {
        isSystem ? .outOfRotation : .playlist(id: playlistID)
    }

    var body: some View {
        Group {
            if let playlist {
                content(playlist)
            } else if let placeholder, isLoading {
                // Paint header + disabled actions immediately from the list row.
                content(Self.shell(from: placeholder), songsReady: false)
            } else if isLoading {
                LoadingStateView()
            } else if let error {
                ErrorStateView(message: error) { Task { await load() } }
            }
        }
        .navigationTitle(prefersInlineTitle
                         ? "Your Library"
                         : "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar { toolbarContent }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            removeConfirmTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(removeConfirmButtonTitle, role: .destructive) {
                Task { await deleteOrHidePlaylist() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeConfirmMessage)
        }
        .sheet(isPresented: $showAddSongs) {
            NavigationStack {
                PlaylistAddSongsView(playlistID: playlistID) {
                    Task { await load() }
                }
                .dromeSession(session)
            }
        }
        .sheet(isPresented: $showMoreSheet) {
            PlaylistMoreSheet(
                playlistName: playlist?.name ?? placeholder?.name ?? "Playlist",
                isSystem: isSystem,
                isEditing: isEditing,
                isPublic: playlist?.isPublic ?? false,
                songCount: playlist?.songs.count ?? 0,
                isPresented: $showMoreSheet,
                onAddSongs: { showAddSongs = true },
                onRename: {
                    renameText = playlist?.name ?? ""
                    showRename = true
                },
                onToggleEdit: {
                    isEditing.toggle()
                    if isEditing, let playlist {
                        visibleSongCount = max(visibleSongCount, playlist.songs.count)
                    }
                },
                onShare: {
                    guard let playlist else { return }
                    PlaylistShare.present(playlist: playlist.asPlaylist, songs: playlist.songs)
                },
                onTogglePublic: { Task { await togglePublic() } },
                onPlayNext: {
                    guard let songs = playlist?.songs, !songs.isEmpty else { return }
                    player.playNext(songs)
                    flash(songs.count == 1 ? "Playing next" : "Playing \(songs.count) next")
                },
                onAddToQueue: {
                    guard let songs = playlist?.songs, !songs.isEmpty else { return }
                    player.addToQueue(songs)
                    flash(songs.count == 1 ? "Added to queue" : "Added \(songs.count) to queue")
                },
                onDownload: {
                    guard let playlist else { return }
                    let songs = playlist.songs
                    guard !songs.isEmpty else { return }
                    downloads.download(
                        songs,
                        playlistId: playlist.id,
                        playlistName: playlist.name)
                    flash("Downloading…")
                },
                onBulkOutOfRotation: { showBulkOORConfirm = true },
                onRemoveDuplicates: { showDuplicatesConfirm = true },
                duplicateCount: duplicateIndexes.count,
                onHide: {
                    hidePlaylistLocally()
                },
                onDelete: { showDeleteConfirm = true },
                canServerDelete: !removesViaHide
            )
            .dromeSession(session)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: coverPickerItem) { _, item in
            guard let item else { return }
            Task { await uploadCover(from: item) }
        }
        .confirmationDialog(
            "Mark All Out of Rotation?",
            isPresented: $showBulkOORConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark Songs Out of Rotation") {
                Task { await bulkMarkOutOfRotation() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tracks stay playable on demand but leave shuffle and autoplay. Songs that also live in other playlists are skipped until every playlist they belong to is marked too.")
        }
        .confirmationDialog(
            "Remove Duplicates?",
            isPresented: $showDuplicatesConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Duplicates", role: .destructive) {
                Task { await removeDuplicates() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = duplicateIndexes.count
            Text(count == 1
                  ? "Keeps the first copy of each song. 1 extra copy will be removed."
                  : "Keeps the first copy of each song. \(count) extra copies will be removed.")
        }
        .overlay(alignment: .bottom) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: statusMessage)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !prefersInlineTitle {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(playlist?.name ?? placeholder?.name ?? "Playlist")
                        .font(.headline)
                        .lineLimit(1)
                    if isFullyDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(DromeTheme.muted)
                            .accessibilityLabel("Downloaded")
                    }
                }
            }
        }
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { isEditing = false }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showMoreSheet = true
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
            }
            .accessibilityLabel("More")
        }
    }

    private static func shell(from placeholder: Playlist) -> PlaylistWithSongs {
        PlaylistWithSongs(
            id: placeholder.id,
            name: placeholder.name,
            comment: placeholder.comment,
            owner: placeholder.owner,
            isPublic: placeholder.isPublic,
            songCount: placeholder.songCount,
            duration: placeholder.duration,
            coverArt: placeholder.coverArt,
            entry: [])
    }

    private func content(_ playlist: PlaylistWithSongs, songsReady: Bool = true) -> some View {
        let allSongs = playlist.songs
        let visible = Array(allSongs.prefix(visibleSongCount))
        let canPlay = songsReady && !allSongs.isEmpty

        return List {
            Section {
                playlistHeader(playlist)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))

                LibraryPlayShuffleRow(
                    canPlay: canPlay,
                    songsReady: songsReady,
                    onPlay: {
                        player.play(
                            allSongs, startAt: 0,
                            context: PlaybackContext(label: playlist.name, kind: contextKind))
                    },
                    onShuffle: {
                        player.playShuffled(
                            allSongs,
                            context: PlaybackContext(label: playlist.name, kind: contextKind))
                    }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if !isSystem {
                    Button {
                        showAddSongs = true
                    } label: {
                        Label("Add songs", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowBackground(DromeTheme.elevated)
                }

                if isSystem {
                    Text("Tracks here stay playable on demand but are excluded from shuffle and autoplay. Manual adds and removes always win over rating automation.")
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(Color.clear)
                } else if playlist.isPublic == true {
                    Label("Shared — anyone with access can edit", systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(DromeTheme.accent)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if !songsReady {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("Loading tracks…")
                            .font(.subheadline)
                            .foregroundStyle(DromeTheme.muted)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if allSongs.isEmpty {
                    Text(isSystem ? "Nothing out of rotation." : "No songs yet. Tap Add songs.")
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(Color.clear)
                }

                ForEach(Array(visible.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, showAlbum: true) {
                            guard !isEditing else { return }
                            player.play(allSongs, startAt: index,
                                        context: PlaybackContext(label: playlist.name, kind: contextKind))
                        }
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                .onMove(perform: isEditing && !isSystem ? move : nil)
                .onDelete(perform: isSystem ? nil : deleteSongs)

                if songsReady, visibleSongCount < allSongs.count {
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

            if !isSystem, songsReady, allSongs.count >= 2 {
                suggestionsSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .task(id: "\(playlistID)-\(allSongs.count)-\(suggestionRefreshToken)") {
            await loadSuggestions()
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            if suggestionsLoading && suggestions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Text("Finding songs that fit…")
                        .font(.subheadline)
                        .foregroundStyle(DromeTheme.muted)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if let suggestionsError, suggestions.isEmpty {
                Text(suggestionsError)
                    .font(.subheadline)
                    .foregroundStyle(DromeTheme.muted)
                    .listRowBackground(Color.clear)
            } else if suggestions.isEmpty {
                Text("Add a few more tracks and we’ll suggest songs that match this playlist’s vibe.")
                    .font(.subheadline)
                    .foregroundStyle(DromeTheme.muted)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(suggestions) { item in
                    suggestionRow(item)
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
        } header: {
            HStack {
                Text("Suggested for this playlist")
                Spacer()
                if !suggestions.isEmpty || suggestionsError != nil {
                    Button {
                        suggestionRefreshToken &+= 1
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(suggestionsLoading)
                    .accessibilityLabel("Refresh suggestions")
                }
            }
        } footer: {
            Text("Picks similar artists and genres from what’s already in the list.")
        }
    }

    private func suggestionRow(_ item: PlaylistSongSuggester.Suggestion) -> some View {
        // Custom row so List doesn't swallow the + button (SongRow's whole-row
        // tap gesture fights nested Buttons inside List).
        HStack(spacing: 12) {
            Button {
                player.play(
                    [item.song], startAt: 0,
                    context: PlaybackContext(label: item.song.title, kind: .search))
            } label: {
                HStack(spacing: 12) {
                    RemoteImage(url: session.artworkURL(for: item.song, size: 96))
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.song.title)
                            .font(DromeTheme.rowTitle)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(suggestionSubtitle(item))
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(item.song.title)")

            Button {
                Task { await addSuggestion(item.song) }
            } label: {
                Group {
                    if addingSuggestionIDs.contains(item.song.id) {
                        ProgressView()
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(DromeTheme.accent)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(addingSuggestionIDs.contains(item.song.id))
            .accessibilityLabel("Add \(item.song.title) to playlist")
        }
    }

    private func suggestionSubtitle(_ item: PlaylistSongSuggester.Suggestion) -> String {
        let artist = item.song.displayArtist
        if artist.isEmpty { return item.reason }
        return "\(artist) · \(item.reason)"
    }

    private func playlistHeader(_ playlist: PlaylistWithSongs) -> some View {
        VStack(spacing: 14) {
            ZStack {
                playlistHeroArtwork(playlist)
                .id("\(playlist.id)-\(coverBump)")
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                .overlay {
                    if isUploadingCover {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.black.opacity(0.45))
                        ProgressView()
                    }
                }
            }

            VStack(spacing: 6) {
                if prefersInlineTitle {
                    EmptyView()
                } else {
                    HStack(spacing: 8) {
                        Text(playlist.name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        if isFullyDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(DromeTheme.muted)
                                .accessibilityLabel("Downloaded")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Text(Playlist.songCountLabel(playlist.songs.count))
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)

                if !isSystem {
                    HStack(spacing: 16) {
                        Button {
                            renameText = playlist.name
                            showRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DromeTheme.accent)

                        PhotosPicker(selection: $coverPickerItem, matching: .images) {
                            Label("Cover", systemImage: "photo")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DromeTheme.accent)
                        .disabled(isUploadingCover)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        if let cached = LibraryDetailCache.playlist(playlistID) {
            playlist = cached
            visibleSongCount = ProgressiveSongReveal.clampInitial(total: cached.songs.count)
            isLoading = false
        } else {
            isLoading = true
        }
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await session.client.playlist(id: playlistID)
            visibleSongCount = ProgressiveSongReveal.clampInitial(total: loaded.songs.count)
            playlist = loaded
            LibraryDetailCache.store(playlist: loaded)
            let songs = loaded.songs
            let coverIDs = PlaylistCoverStore.coverIDs(from: songs)
            if !coverIDs.isEmpty,
               !PlaylistCoverStore.hasCustom(playlistID, userKey: session.account.userKey) {
                PlaylistCoverStore.rememberCoverIDs(
                    coverIDs, playlistID: playlistID, userKey: session.account.userKey)
            }
            var coverURLs = songs.prefix(24).compactMap { session.artworkURL(for: $0, size: 96) }
            if let hero = session.artworkURL(id: loaded.coverArt ?? loaded.id, size: 600) {
                coverURLs.insert(hero, at: 0)
            }
            ImageLoader.shared.prefetch(coverURLs, limit: 25, priority: .userInitiated)
            Task {
                await Task.yield()
                ratings.ingest(songs)
            }
        } catch {
            if playlist == nil {
                self.error = error.localizedDescription
            }
        }
    }

    private func uploadCover(from item: PhotosPickerItem) async {
        coverPickerItem = nil
        guard !isSystem else { return }
        isUploadingCover = true
        defer { isUploadingCover = false }
        do {
            guard let transfer = try await item.loadTransferable(type: PlaylistCoverTransfer.self) else {
                flash("Couldn't read that photo")
                return
            }
            let compressed = Self.compressCover(transfer.data) ?? transfer.data
            try await session.client.uploadPlaylistCover(
                id: playlistID,
                imageData: compressed,
                filename: "cover.jpg"
            )
            let coverID = PlaylistCoverStore.serverCoverID(
                coverArt: playlist?.coverArt, playlistID: playlistID)
            ImageLoader.shared.invalidateCover(
                id: coverID, host: session.account.serverURL.host)
            ImageLoader.shared.invalidateCover(
                id: playlistID, host: session.account.serverURL.host)
            coverBump = Date().timeIntervalSince1970
            PlaylistCoverStore.markCustom(playlistID, userKey: session.account.userKey)
            await load()
            flash("Cover updated")
        } catch {
            flash(error.localizedDescription)
        }
    }

    /// Always the playlist’s Navidrome cover (custom upload or server mosaic).
    @ViewBuilder
    private func playlistHeroArtwork(_ playlist: PlaylistWithSongs) -> some View {
        PlaylistArtwork(
            playlistID: playlist.id,
            coverArt: playlist.coverArt,
            session: session,
            size: 600,
            cacheBust: coverBump)
    }

    private static func compressCover(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return data }
        let src = image.size
        let side = min(src.width, src.height)
        guard side > 0 else { return data }
        let origin = CGPoint(x: (src.width - side) / 2, y: (src.height - side) / 2)
        let maxSide: CGFloat = 1600
        let output = min(side, maxSide)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: output, height: output))
        let squared = renderer.image { _ in
            image.draw(in: CGRect(x: -origin.x * output / side,
                                  y: -origin.y * output / side,
                                  width: src.width * output / side,
                                  height: src.height * output / side))
        }
        return squared.jpegData(compressionQuality: 0.85)
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard var playlist, !isSystem else { return }
        var songs = playlist.songs
        songs.move(fromOffsets: source, toOffset: destination)
        playlist.entry = songs
        self.playlist = playlist
        Task {
            try? await session.client.replacePlaylist(id: playlist.id, name: playlist.name,
                                                      songIds: songs.map(\.id))
        }
    }

    private func deleteSongs(at offsets: IndexSet) {
        guard var playlist, !isSystem else { return }
        let indices = Array(offsets).sorted()
        playlist.entry?.remove(atOffsets: offsets)
        self.playlist = playlist
        Task {
            try? await session.client.updatePlaylist(id: playlist.id, removeIndices: indices)
            await load()
        }
    }

    /// Indexes of every song copy after the first (Aura Remove Duplicates).
    private var duplicateIndexes: [Int] {
        let songs = playlist?.songs ?? []
        var seen = Set<String>()
        return songs.indices.filter { !seen.insert(songs[$0].id).inserted }
    }

    private func removeDuplicates() async {
        guard !isSystem else { return }
        let copies = duplicateIndexes
        guard !copies.isEmpty, var playlist else { return }
        let songs = playlist.songs
        let removed = Set(copies)
        playlist.entry = songs.indices.filter { !removed.contains($0) }.map { songs[$0] }
        self.playlist = playlist
        do {
            try await session.client.updatePlaylist(id: playlist.id, removeIndices: copies)
            flash(copies.count == 1 ? "Removed 1 duplicate" : "Removed \(copies.count) duplicates")
            await load()
        } catch {
            flash(error.localizedDescription)
            await load()
        }
    }

    private func rename() async {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isSystem else { return }
        do {
            try await session.client.updatePlaylist(id: playlistID, name: name)
            await load()
            flash("Renamed")
        } catch {
            flash(error.localizedDescription)
        }
    }

    private func togglePublic() async {
        guard let playlist, !isSystem else { return }
        let next = !(playlist.isPublic ?? false)
        do {
            try await session.client.updatePlaylist(id: playlistID, isPublic: next)
            await load()
            flash(next ? "Playlist is public" : "Playlist is private")
        } catch {
            flash(error.localizedDescription)
        }
    }

    private var removesViaHide: Bool {
        let candidate = playlist?.asPlaylist ?? placeholder
        guard let candidate else { return false }
        return PlaylistOrderStore.shouldHideInsteadOfDelete(
            candidate, username: session.account.username)
    }

    private var removeConfirmTitle: String {
        removesViaHide ? "Hide Playlist?" : "Delete Playlist?"
    }

    private var removeConfirmButtonTitle: String {
        let name = playlist?.name ?? placeholder?.name ?? "Playlist"
        return removesViaHide ? "Hide “\(name)”" : "Delete “\(name)”"
    }

    private var removeConfirmMessage: String {
        if removesViaHide {
            return "Hides this playlist from your library only. Other people on the server keep it."
        }
        return "This removes the playlist from Navidrome. Songs stay in your library."
    }

    private func hidePlaylistLocally() {
        guard !isSystem else { return }
        let userKey = session.account.userKey
        PlaylistOrderStore.hide(playlistID, userKey: userKey)
        PlaylistOrderStore.clearBulkOOR(playlistID, userKey: userKey)
        onDeleted?()
        dismiss()
    }

    private func deleteOrHidePlaylist() async {
        guard !isSystem else { return }
        if removesViaHide {
            hidePlaylistLocally()
            return
        }
        do {
            try await session.client.deletePlaylist(id: playlistID)
            let userKey = session.account.userKey
            PlaylistOrderStore.unhide(playlistID, userKey: userKey)
            PlaylistOrderStore.clearBulkOOR(playlistID, userKey: userKey)
            onDeleted?()
            dismiss()
        } catch {
            flash(error.localizedDescription)
        }
    }

    private func bulkMarkOutOfRotation() async {
        guard let pl = playlist, !pl.songs.isEmpty, !isSystem else { return }
        let userKey = session.account.userKey
        let playlistID = pl.id
        let songs = pl.songs

        // Remember this playlist was bulk-marked so shared tracks can graduate
        // into OOR only once every playlist they belong to is marked.
        PlaylistOrderStore.markBulkOOR(playlistID, userKey: userKey)
        let marked = PlaylistOrderStore.bulkOORMarkedIDs(userKey: userKey)

        let toMark = await songsEligibleForBulkOOR(
            songs: songs,
            playlistID: playlistID,
            markedPlaylistIDs: marked,
            userKey: userKey)

        await rotation.addAll(toMark, manual: true)
        let skipped = songs.count - toMark.count
        if skipped > 0 {
            flash("Marked \(toMark.count) out of rotation · \(skipped) still in other playlists")
        } else {
            flash("Marked \(toMark.count) out of rotation")
        }
    }

    /// Songs that only belong to bulk-OOR-marked playlists (plus this one).
    private func songsEligibleForBulkOOR(
        songs: [Song],
        playlistID: String,
        markedPlaylistIDs: Set<String>,
        userKey: String
    ) async -> [Song] {
        var membership: [String: Set<String>] = [:]
        for song in songs {
            membership[song.id] = [playlistID]
        }

        let lists = (try? await session.client.playlists()) ?? []
        let hidden = PlaylistOrderStore.hiddenIDs(userKey: userKey)
        let others = lists.filter {
            $0.id != playlistID
                && $0.name != RotationManager.playlistName
                && !hidden.contains($0.id)
        }

        await withTaskGroup(of: (String, Set<String>).self) { group in
            for other in others {
                group.addTask {
                    let full = try? await session.client.playlist(id: other.id)
                    return (other.id, Set((full?.songs ?? []).map(\.id)))
                }
            }
            for await (otherID, ids) in group {
                for song in songs where ids.contains(song.id) {
                    membership[song.id, default: [playlistID]].insert(otherID)
                }
            }
        }

        return songs.filter { song in
            let containers = membership[song.id] ?? [playlistID]
            return containers.isSubset(of: markedPlaylistIDs)
        }
    }

    private func loadSuggestions() async {
        guard !isSystem else {
            suggestions = []
            return
        }
        let songs = playlist?.songs ?? []
        guard songs.count >= 2 else {
            suggestions = []
            suggestionsError = nil
            return
        }
        suggestionsLoading = true
        suggestionsError = nil
        defer { suggestionsLoading = false }

        let excluded = rotation.excludedIDs
        let result = await PlaylistSongSuggester.suggest(
            for: songs,
            client: session.client,
            excluding: excluded,
            limit: 12)
        guard !Task.isCancelled else { return }
        suggestions = result
        if result.isEmpty {
            suggestionsError = "Couldn't find fresh matches right now. Try Refresh after adding more songs."
        }
    }

    private func addSuggestion(_ song: Song) async {
        guard !isSystem, !addingSuggestionIDs.contains(song.id) else { return }
        addingSuggestionIDs.insert(song.id)
        defer { addingSuggestionIDs.remove(song.id) }
        do {
            try await session.client.updatePlaylist(id: playlistID, addSongIds: [song.id])
            suggestions.removeAll { $0.song.id == song.id }
            await load()
            flash("Added “\(song.title)”")
        } catch {
            flash(error.localizedDescription)
        }
    }

    private func flash(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if statusMessage == message { statusMessage = nil }
        }
    }
}

private struct PlaylistCoverTransfer: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PlaylistCoverTransfer(data: data)
        }
    }
}

// MARK: - Add songs to a playlist

struct PlaylistAddSongsView: View {
    let playlistID: String
    var onAdded: () -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var isSearching = false
    @State private var addedIDs: Set<String> = []
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(DromeTheme.muted)
                    TextField("Search songs to add", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: query) { _, value in schedule(value) }
                }
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                if isSearching && hits.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(hits.filter { $0.kind == .song }) { hit in
                    if let song = hit.song {
                        Button {
                            Task { await add(song) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title).foregroundStyle(.white)
                                    Text(song.artist ?? "")
                                        .font(.caption)
                                        .foregroundStyle(DromeTheme.muted)
                                }
                                Spacer()
                                Image(systemName: addedIDs.contains(song.id) ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(addedIDs.contains(song.id) ? DromeTheme.accent : .white)
                            }
                        }
                        .disabled(addedIDs.contains(song.id))
                        .listRowBackground(DromeTheme.background)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DromeTheme.background)
        .navigationTitle("Add Songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if let playlist = try? await session.client.playlist(id: playlistID) {
                addedIDs = Set(playlist.songs.map(\.id))
            }
        }
    }

    private func schedule(_ raw: String) {
        debounceTask?.cancel()
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { hits = []; return }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            if let result = try? await session.client.search(q, artistCount: 0, albumCount: 0, songCount: 40) {
                hits = SearchRanker.rank(query: q, result: result)
            }
        }
    }

    private func add(_ song: Song) async {
        do {
            try await session.client.updatePlaylist(id: playlistID, addSongIds: [song.id])
            addedIDs.insert(song.id)
            onAdded()
        } catch {}
    }
}

// MARK: - Add a song to an existing playlist (from song context menu)

struct AddToPlaylistView: View {
    let song: Song

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [Playlist] = []
    @State private var alreadyInPlaylistIDs: Set<String> = []
    @State private var pendingPlaylistIDs: Set<String> = []
    @State private var statusMessage: String?
    @State private var showCreate = false
    @State private var newName = ""
    @State private var error: String?

    /// Visible (non-hidden) playlists in Library order, excluding Out of Rotation.
    private var visiblePlaylists: [Playlist] {
        let withoutOOR = playlists.filter { $0.name != RotationManager.playlistName }
        return PlaylistOrderStore.visibleOrdered(
            withoutOOR,
            userKey: session.account.userKey,
            serverKey: session.account.serverKey
        )
    }

    var body: some View {
        List {
            Section {
                Button {
                    showCreate = true
                } label: {
                    Label("New Playlist", systemImage: "plus.circle.fill")
                        .foregroundStyle(DromeTheme.accent)
                }
                .listRowBackground(DromeTheme.elevated)
            }

            Section("Your playlists") {
                ForEach(visiblePlaylists) { playlist in
                    Button {
                        Task { await add(to: playlist) }
                    } label: {
                        HStack(spacing: 12) {
                            playlistCoverThumb(playlist)
                            Text(playlist.name)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if pendingPlaylistIDs.contains(playlist.id) {
                                ProgressView()
                            } else if alreadyInPlaylistIDs.contains(playlist.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(DromeTheme.accent)
                            } else {
                                Text(playlist.songCountLabel)
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                        }
                    }
                    .disabled(pendingPlaylistIDs.contains(playlist.id)
                              || alreadyInPlaylistIDs.contains(playlist.id))
                    .listRowBackground(DromeTheme.elevated)
                    .accessibilityLabel(playlistAccessibilityLabel(playlist))
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .listRowBackground(Color.clear)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .navigationTitle("Add to Playlist")
        .task {
            playlists = (try? await session.client.playlists()) ?? []
        }
        .alert("New Playlist", isPresented: $showCreate) {
            TextField("Name", text: $newName)
            Button("Create") {
                Task { await createAndAdd() }
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    @ViewBuilder
    private func playlistCoverThumb(_ playlist: Playlist) -> some View {
        PlaylistArtwork(
            playlistID: playlist.id,
            coverArt: playlist.coverArt,
            session: session,
            size: 96)
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }

    private func playlistAccessibilityLabel(_ playlist: Playlist) -> String {
        if alreadyInPlaylistIDs.contains(playlist.id) {
            return "\(playlist.name), already added"
        }
        return "\(playlist.name), \(playlist.songCountLabel)"
    }

    private func add(to playlist: Playlist) async {
        pendingPlaylistIDs.insert(playlist.id)
        defer { pendingPlaylistIDs.remove(playlist.id) }
        do {
            let detail = try await session.client.playlist(id: playlist.id)
            if detail.songs.contains(where: { $0.id == song.id }) {
                alreadyInPlaylistIDs.insert(playlist.id)
                statusMessage = "Already in “\(playlist.name)”"
                return
            }
            try await session.client.updatePlaylist(id: playlist.id, addSongIds: [song.id])
            alreadyInPlaylistIDs.insert(playlist.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createAndAdd() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty else { return }
        do {
            let created = try await session.client.createPlaylist(name: name, songIds: [song.id])
            _ = created
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Playlist more sheet (avoids Menu flicker while player ticks)

struct PlaylistMoreSheet: View {
    let playlistName: String
    let isSystem: Bool
    let isEditing: Bool
    let isPublic: Bool
    let songCount: Int
    @Binding var isPresented: Bool
    var onAddSongs: () -> Void
    var onRename: () -> Void
    var onToggleEdit: () -> Void
    var onShare: () -> Void
    var onTogglePublic: () -> Void
    var onPlayNext: () -> Void
    var onAddToQueue: () -> Void
    var onDownload: () -> Void
    var onBulkOutOfRotation: () -> Void
    var onRemoveDuplicates: () -> Void = {}
    var duplicateCount: Int = 0
    var onHide: () -> Void
    var onDelete: () -> Void
    /// False for shared / others' playlists — only Hide is offered.
    var canServerDelete: Bool = true

    var body: some View {
        NavigationStack {
            List {
                if !isSystem {
                    Section {
                        Button {
                            dismissThen(onAddSongs)
                        } label: {
                            Label("Add Songs", systemImage: "plus")
                        }
                        .listRowBackground(DromeTheme.elevated)

                        Button {
                            dismissThen(onRename)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .listRowBackground(DromeTheme.elevated)

                        Button {
                            dismissThen(onToggleEdit)
                        } label: {
                            Label(isEditing ? "Done Reordering" : "Edit & Reorder",
                                  systemImage: "arrow.up.arrow.down")
                        }
                        .listRowBackground(DromeTheme.elevated)

                        Button {
                            dismissThen(onShare)
                        } label: {
                            Label("Share Playlist", systemImage: "square.and.arrow.up")
                        }
                        .listRowBackground(DromeTheme.elevated)

                        Button {
                            dismissThen(onTogglePublic)
                        } label: {
                            Label(isPublic ? "Make Private" : "Make Public on Server",
                                  systemImage: "person.2")
                        }
                        .listRowBackground(DromeTheme.elevated)

                        if duplicateCount > 0 {
                            Button(role: .destructive) {
                                dismissThen(onRemoveDuplicates)
                            } label: {
                                Label("Remove Duplicates", systemImage: "square.on.square.dashed")
                            }
                            .listRowBackground(DromeTheme.elevated)
                        }
                    } footer: {
                        Text("Share sends a Drome link. Make Public lets other accounts on your Navidrome server open and edit the playlist.")
                    }

                    Section {
                        Button {
                            dismissThen(onBulkOutOfRotation)
                        } label: {
                            Label("Mark All Out of Rotation", systemImage: "lock")
                        }
                        .disabled(songCount == 0)
                        .listRowBackground(DromeTheme.elevated)
                    } footer: {
                        Text("Keeps tracks in this playlist out of shuffle and autoplay. Songs shared with other playlists wait until those playlists are marked too. They’re still playable anytime.")
                    }
                }

                Section {
                    Button {
                        dismissThen(onPlayNext)
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .disabled(songCount == 0)
                    .listRowBackground(DromeTheme.elevated)

                    Button {
                        dismissThen(onAddToQueue)
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                    .disabled(songCount == 0)
                    .listRowBackground(DromeTheme.elevated)

                    Button {
                        dismissThen(onDownload)
                    } label: {
                        Label("Download Playlist", systemImage: "arrow.down.circle")
                    }
                    .disabled(songCount == 0)
                    .listRowBackground(DromeTheme.elevated)
                } footer: {
                    Text("Play Next inserts the playlist at the front of your queue. Add to Queue appends it at the end.")
                }

                if !isSystem {
                    Section {
                        Button {
                            dismissThen(onHide)
                        } label: {
                            Label("Hide from My Library", systemImage: "eye.slash")
                        }
                        .listRowBackground(DromeTheme.elevated)

                        // Shared / others' lists can't be deleted server-side —
                        // Hide above already covers removal from your library.
                        if canServerDelete {
                            Button(role: .destructive) {
                                dismissThen(onDelete)
                            } label: {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                            .listRowBackground(DromeTheme.elevated)
                        }
                    } footer: {
                        Text(
                            canServerDelete
                                ? "Hide is local to your account. Delete removes the playlist from the server for everyone."
                                : "Hide is local to your account. Shared playlists can’t be deleted for everyone."
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DromeTheme.background)
            .navigationTitle(playlistName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func dismissThen(_ action: @escaping () -> Void) {
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: action)
    }
}
