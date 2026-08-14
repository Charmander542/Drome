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
    @State private var statusMessage: String?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var isUploadingCover = false
    @State private var coverBump: TimeInterval = 0
    /// Rows painted so far — full `playlist.songs` stays available for Play/Shuffle.
    @State private var visibleSongCount = ProgressiveSongReveal.initial

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
        .confirmationDialog("Delete Playlist?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete “\(playlist?.name ?? "Playlist")”", role: .destructive) {
                Task { await deletePlaylist() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the playlist from Navidrome. Songs stay in your library.")
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
                onTogglePublic: { Task { await togglePublic() } },
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
                onDelete: { showDeleteConfirm = true }
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
            Button("Mark \(playlist?.songs.count ?? 0) Songs Out of Rotation") {
                Task { await bulkMarkOutOfRotation() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These tracks stay playable on demand but are excluded from shuffle and autoplay.")
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
                            .foregroundStyle(DromeTheme.accent)
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
                Image(systemName: "ellipsis.circle")
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

                HStack(spacing: 12) {
                    Button {
                        player.play(allSongs, startAt: 0,
                                    context: PlaybackContext(label: playlist.name, kind: contextKind))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DromeTheme.accent)
                    .foregroundStyle(.white)
                    .disabled(!canPlay)

                    Button {
                        player.playShuffled(allSongs,
                                            context: PlaybackContext(label: playlist.name, kind: contextKind))
                    } label: {
                        if songsReady {
                            Label("Shuffle", systemImage: "shuffle")
                                .frame(maxWidth: .infinity)
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(!canPlay)
                }
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
                    SongRow(song: song, showAlbum: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
    }

    private func playlistHeader(_ playlist: PlaylistWithSongs) -> some View {
        VStack(spacing: 14) {
            ZStack {
                RemoteImage(
                    url: session.artworkURL(id: playlist.coverArt ?? playlist.id, size: 600),
                    placeholderSymbol: "music.note.list"
                )
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
                                .foregroundStyle(DromeTheme.accent)
                                .accessibilityLabel("Downloaded")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Text("\(playlist.songs.count) songs")
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
            if let url = session.artworkURL(id: playlist?.coverArt ?? playlistID, size: 600) {
                ImageLoader.shared.removeCached(for: url)
            }
            if let url = session.artworkURL(id: playlistID, size: 600) {
                ImageLoader.shared.removeCached(for: url)
            }
            if let url = session.artworkURL(id: playlistID, size: 300) {
                ImageLoader.shared.removeCached(for: url)
            }
            coverBump = Date().timeIntervalSince1970
            await load()
            flash("Cover updated")
        } catch {
            flash(error.localizedDescription)
        }
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

    private func deletePlaylist() async {
        guard !isSystem else { return }
        do {
            try await session.client.deletePlaylist(id: playlistID)
            onDeleted?()
            dismiss()
        } catch {
            flash(error.localizedDescription)
        }
    }

    private func bulkMarkOutOfRotation() async {
        guard let songs = playlist?.songs, !songs.isEmpty, !isSystem else { return }
        await rotation.addAll(songs, manual: true)
        flash("Marked \(songs.count) out of rotation")
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
                ForEach(playlists.filter { $0.name != RotationManager.playlistName }) { playlist in
                    Button {
                        Task { await add(to: playlist) }
                    } label: {
                        HStack {
                            Text(playlist.name).foregroundStyle(.white)
                            Spacer()
                            if pendingPlaylistIDs.contains(playlist.id) {
                                ProgressView()
                            } else if alreadyInPlaylistIDs.contains(playlist.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(DromeTheme.accent)
                            } else if let count = playlist.songCount {
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                        }
                    }
                    .disabled(pendingPlaylistIDs.contains(playlist.id)
                              || alreadyInPlaylistIDs.contains(playlist.id))
                    .listRowBackground(DromeTheme.elevated)
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
    var onTogglePublic: () -> Void
    var onDownload: () -> Void
    var onBulkOutOfRotation: () -> Void
    var onDelete: () -> Void

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
                            dismissThen(onTogglePublic)
                        } label: {
                            Label(isPublic ? "Make Private" : "Make Public / Share",
                                  systemImage: "person.2")
                        }
                        .listRowBackground(DromeTheme.elevated)
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
                        Text("Keeps every track in this playlist out of shuffle and autoplay. They’re still playable anytime.")
                    }
                }

                Section {
                    Button {
                        dismissThen(onDownload)
                    } label: {
                        Label("Download Playlist", systemImage: "arrow.down.circle")
                    }
                    .disabled(songCount == 0)
                    .listRowBackground(DromeTheme.elevated)
                }

                if !isSystem {
                    Section {
                        Button(role: .destructive) {
                            dismissThen(onDelete)
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                        .listRowBackground(DromeTheme.elevated)
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
