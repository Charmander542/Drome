import SwiftUI

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

    private var isSystem: Bool {
        guard let playlist else {
            return placeholder.map { rotation.isSystemPlaylist($0) } ?? false
        }
        return playlist.name == RotationManager.playlistName
    }

    private var contextKind: PlaybackContext.Kind {
        isSystem ? .outOfRotation : .playlist(id: playlistID)
    }

    var body: some View {
        Group {
            if isLoading && playlist == nil {
                LoadingStateView()
            } else if let error, playlist == nil {
                ErrorStateView(message: error) { Task { await load() } }
            } else if let playlist {
                content(playlist)
            }
        }
        .navigationTitle(prefersInlineTitle
                         ? "Your Library"
                         : (playlist?.name ?? placeholder?.name ?? "Playlist"))
        .navigationBarTitleDisplayMode(prefersInlineTitle ? .inline : .large)
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
                onToggleEdit: { isEditing.toggle() },
                onTogglePublic: { Task { await togglePublic() } },
                onDownload: {
                    guard let songs = playlist?.songs else { return }
                    downloads.download(songs, albumName: playlist?.name)
                    flash("Downloading…")
                },
                onBulkOutOfRotation: { showBulkOORConfirm = true },
                onDelete: { showDeleteConfirm = true }
            )
            .dromeSession(session)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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

    private func content(_ playlist: PlaylistWithSongs) -> some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Button {
                        player.play(playlist.songs, startAt: 0,
                                    context: PlaybackContext(label: playlist.name, kind: contextKind))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DromeTheme.accent)
                    .foregroundStyle(.white)

                    Button {
                        player.playShuffled(playlist.songs,
                                            context: PlaybackContext(label: playlist.name, kind: contextKind))
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
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
                if playlist.songs.isEmpty {
                    Text(isSystem ? "Nothing out of rotation." : "No songs yet. Tap Add songs.")
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(Color.clear)
                }
                ForEach(Array(playlist.songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, showAlbum: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isEditing else { return }
                            player.play(playlist.songs, startAt: index,
                                        context: PlaybackContext(label: playlist.name, kind: contextKind))
                        }
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                .onMove(perform: isEditing && !isSystem ? move : nil)
                .onDelete(perform: isSystem ? nil : deleteSongs)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await session.client.playlist(id: playlistID)
            playlist = loaded
            ratings.ingest(loaded.songs)
        } catch {
            self.error = error.localizedDescription
        }
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
                                Image(systemName: addedIDs.contains(song.id) ? "checkmark.circle.fill" : "plus.circle")
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
                        Task {
                            try? await session.client.updatePlaylist(id: playlist.id, addSongIds: [song.id])
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Text(playlist.name).foregroundStyle(.white)
                            Spacer()
                            if let count = playlist.songCount {
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                        }
                    }
                    .listRowBackground(DromeTheme.elevated)
                }
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
