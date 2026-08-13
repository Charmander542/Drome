import SwiftUI
import UIKit

struct WishlistView: View {
    @EnvironmentObject private var session: AppSession

    @State private var entries: [WishlistEntry] = []
    @State private var searchQuery = ""
    @State private var searchResults: [SpotifySearchHit] = []
    @State private var pasteURL = ""
    @State private var isLoading = false
    @State private var isSearching = false
    @State private var addingIDs: Set<String> = []
    @State private var isAddingPaste = false
    @State private var error: String?
    @State private var importBanner: String?
    @State private var shareTarget: WishlistEntry?
    @State private var shareUsername = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var groupByPlaylist = false

    var body: some View {
        Group {
            if session.wishlist == nil {
                EmptyStateView(
                    title: "Wishlist not configured",
                    systemImage: "heart",
                    message: "Set your companion server URL when signing in (or in Settings) to keep a shared “songs to go get” list.")
            } else if isLoading && entries.isEmpty {
                LoadingStateView()
            } else {
                list
            }
        }
        .navigationTitle("Wishlist")
        .task { await load() }
        .refreshable { await load() }
        .alert("Share entry", isPresented: Binding(
            get: { shareTarget != nil },
            set: { if !$0 { shareTarget = nil } }
        )) {
            TextField("Navidrome username", text: $shareUsername)
            Button("Share") {
                guard let entry = shareTarget else { return }
                Task { await share(entry, with: shareUsername) }
            }
            Button("Cancel", role: .cancel) { shareTarget = nil }
        } message: {
            Text("Make this wishlist entry visible to another Navidrome user on your server.")
        }
        .onChange(of: searchQuery) { _, newValue in
            scheduleSearch(newValue)
        }
    }

    private var list: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DromeTheme.muted)
                    TextField("Search Spotify", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if isSearching {
                        ProgressView()
                    } else if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DromeTheme.muted)
                        }
                    }
                }
                .listRowBackground(DromeTheme.elevated)
            } footer: {
                Text("Search tracks, albums, or playlists — missing playlist tracks are queued for download.")
            }

            if !searchResults.isEmpty {
                Section("Results") {
                    ForEach(searchResults) { hit in
                        searchRow(hit)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Paste Spotify playlist or track links", text: $pasteURL, axis: .vertical)
                            .lineLimit(2...5)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        Button {
                            pasteFromClipboard()
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(DromeTheme.accent)
                        }
                        .accessibilityLabel("Paste from clipboard")
                        .disabled(isAddingPaste)

                        Button {
                            Task { await addPaste() }
                        } label: {
                            if isAddingPaste {
                                ProgressView()
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(DromeTheme.accent)
                            }
                        }
                        .disabled(isAddingPaste || pasteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Import pasted links")
                    }
                }
                .listRowBackground(DromeTheme.elevated)
            } header: {
                Text("Paste for download")
            } footer: {
                Text("Paste a Spotify playlist URL (or several track links). Tracks you already own are skipped; the rest queue for download into Navidrome.")
            }

            if let importBanner {
                Section {
                    Text(importBanner)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DromeTheme.accent)
                }
                .listRowBackground(Color.clear)
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.subheadline)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                Toggle("Group by Spotify playlist", isOn: $groupByPlaylist)
                    .listRowBackground(DromeTheme.elevated)
            }

            if groupByPlaylist {
                groupedWishlistSections
            } else {
                Section("Wishlist") {
                    if entries.isEmpty {
                        Text("Nothing here yet. Search Spotify or paste a playlist above.")
                            .foregroundStyle(DromeTheme.muted)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
    }

    @ViewBuilder
    private var groupedWishlistSections: some View {
        let groups = Dictionary(grouping: entries) { entry -> String in
            let id = entry.sourcePlaylistId ?? ""
            return id.isEmpty ? "__ungrouped__" : id
        }
        let keys = groups.keys.sorted { a, b in
            if a == "__ungrouped__" { return false }
            if b == "__ungrouped__" { return true }
            let an = groups[a]?.first?.sourcePlaylistName ?? a
            let bn = groups[b]?.first?.sourcePlaylistName ?? b
            return an.localizedCaseInsensitiveCompare(bn) == .orderedAscending
        }
        if entries.isEmpty {
            Section("Wishlist") {
                Text("Nothing here yet. Search Spotify or paste a link above.")
                    .foregroundStyle(DromeTheme.muted)
                    .listRowBackground(Color.clear)
            }
        }
        ForEach(keys, id: \.self) { key in
            let items = groups[key] ?? []
            Section {
                ForEach(items) { entry in
                    entryRow(entry)
                }
            } header: {
                Text(key == "__ungrouped__"
                      ? "Individual items"
                      : (items.first?.sourcePlaylistName ?? "Playlist"))
            } footer: {
                if key != "__ungrouped__", items.first?.owner == session.account.username {
                    Button("Remove entire playlist import", role: .destructive) {
                        Task { await deleteSourcePlaylist(key) }
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func searchRow(_ hit: SpotifySearchHit) -> some View {
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
                Text([hit.artist, hit.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
            }
            Spacer()
            if hit.kind == "album" {
                Text("ALBUM")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DromeTheme.muted)
            } else if hit.kind == "playlist" {
                Text("PLAYLIST")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DromeTheme.muted)
            }
            Button {
                Task { await addHit(hit) }
            } label: {
                if addingIDs.contains(hit.id) {
                    ProgressView()
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(DromeTheme.accent)
                }
            }
            .disabled(addingIDs.contains(hit.id))
        }
        .listRowBackground(DromeTheme.background)
    }

    @ViewBuilder
    private func entryRow(_ entry: WishlistEntry) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: entry.coverUrl)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(white: 0.16)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(DromeTheme.rowTitle)
                Text([entry.artist, entry.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                if let statusLine = downloadStatusLine(entry) {
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(statusColor(entry))
                }
                if let sharedBy = entry.sharedBy {
                    Text("Shared by \(sharedBy)")
                        .font(.caption2)
                        .foregroundStyle(DromeTheme.accent)
                }
                if let playlist = entry.sourcePlaylistName, !playlist.isEmpty, !groupByPlaylist {
                    Text("From \(playlist)")
                        .font(.caption2)
                        .foregroundStyle(DromeTheme.muted)
                }
            }
            Spacer()
            if entry.kind == "album" {
                Text("ALBUM")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DromeTheme.muted)
            }
        }
        .opacity(1)
        .listRowBackground(DromeTheme.background)
        .swipeActions(edge: .trailing) {
            if entry.owner == session.account.username {
                Button(role: .destructive) {
                    Task { await delete(entry) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            if entry.owner == session.account.username {
                Button {
                    Task { await toggleAcquired(entry) }
                } label: {
                    Label("Got it", systemImage: "checkmark")
                }
                .tint(DromeTheme.accent)
                Button {
                    shareUsername = ""
                    shareTarget = entry
                } label: {
                    Label("Share", systemImage: "person.badge.plus")
                }
            }
        }
    }

    private func downloadStatusLine(_ entry: WishlistEntry) -> String? {
        switch entry.status {
        case "queued": return "Queued for download"
        case "downloading": return "Downloading…"
        case "failed":
            if let msg = entry.statusMessage, !msg.isEmpty {
                return "Download failed: \(msg)"
            }
            return "Download failed"
        case "done": return entry.acquired ? nil : "Downloaded"
        default: return nil
        }
    }

    private func statusColor(_ entry: WishlistEntry) -> Color {
        switch entry.status {
        case "failed": return .red
        case "downloading", "queued": return DromeTheme.accent
        default: return DromeTheme.muted
        }
    }

    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(query)
        }
    }

    private func runSearch(_ query: String) async {
        guard let client = session.wishlist else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await client.search(query: query)
            error = nil
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard let client = session.wishlist else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            entries = try await client.list()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addHit(_ hit: SpotifySearchHit) async {
        guard let client = session.wishlist else { return }
        addingIDs.insert(hit.id)
        defer { addingIDs.remove(hit.id) }
        error = nil
        do {
            try await applyAddResult(client.add(spotifyLink: hit.spotifyUrl))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addPaste() async {
        guard let client = session.wishlist else { return }
        let raw = pasteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isAddingPaste = true
        error = nil
        importBanner = nil
        defer { isAddingPaste = false }
        do {
            let links = Self.extractSpotifyLinks(from: raw)
            let result: WishlistAddResult
            if links.count > 1 {
                result = try await client.add(spotifyLinks: links)
            } else {
                result = try await client.add(spotifyLink: links.first ?? raw)
            }
            try await applyAddResult(result)
            pasteURL = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            error = "Clipboard is empty."
            return
        }
        pasteURL = text
        error = nil
    }

    /// Pull Spotify URLs/URIs out of a clipboard dump (mirrors server extractor).
    private static func extractSpotifyLinks(from raw: String) -> [String] {
        let pattern = #"(?i)(?:https?://(?:open|play)\.spotify\.com/[^\s<>"']+|https?://spotify\.link/[^\s<>"']+|spotify:(?:track|album|playlist):[0-9A-Za-z]{15,40})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [raw]
        }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var out: [String] = []
        for match in matches {
            var link = ns.substring(with: match.range)
            while let last = link.last, ".,);]}>'\"\n".contains(last) {
                link.removeLast()
            }
            let key = link.lowercased()
            if seen.insert(key).inserted {
                out.append(link)
            }
        }
        return out.isEmpty ? [raw] : out
    }

    private func applyAddResult(_ result: WishlistAddResult) async {
        switch result {
        case .entry(let entry):
            if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[idx] = entry
            } else {
                entries.insert(entry, at: 0)
            }
            let label = entry.kind == "album" ? "Album" : "Track"
            importBanner = "\(label) queued: \(entry.title)"
        case .playlist(let imported):
            for entry in imported.entries.reversed() {
                if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[idx] = entry
                } else {
                    entries.insert(entry, at: 0)
                }
            }
            let name = imported.playlistName ?? imported.sourcePlaylistName
            var parts: [String] = []
            if let name, !name.isEmpty {
                parts.append("Imported “\(name)”")
            } else {
                parts.append("Imported links")
            }
            parts.append("added \(imported.added)")
            if imported.skippedOwned > 0 {
                parts.append("skipped \(imported.skippedOwned) already owned")
            }
            if let failed = imported.failed, !failed.isEmpty {
                parts.append("\(failed.count) failed")
            }
            importBanner = parts.joined(separator: " · ")

            if imported.added == 0 && imported.skippedOwned > 0 {
                error = "All \(imported.skippedOwned) tracks already look like they’re in your library."
            } else {
                error = nil
            }
            if imported.added > 0 || (imported.sourcePlaylistId?.isEmpty == false) {
                groupByPlaylist = true
            }
        }
    }

    private func delete(_ entry: WishlistEntry) async {
        guard let client = session.wishlist else { return }
        try? await client.delete(id: entry.id)
        entries.removeAll { $0.id == entry.id }
    }

    private func deleteSourcePlaylist(_ playlistId: String) async {
        guard let client = session.wishlist else { return }
        try? await client.deleteSourcePlaylist(id: playlistId)
        entries.removeAll { $0.sourcePlaylistId == playlistId }
    }

    private func toggleAcquired(_ entry: WishlistEntry) async {
        guard let client = session.wishlist else { return }
        // “Got it” removes the row — downloads already do this automatically.
        try? await client.setAcquired(id: entry.id, acquired: true)
        entries.removeAll { $0.id == entry.id }
    }

    private func share(_ entry: WishlistEntry, with user: String) async {
        defer { shareTarget = nil }
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = session.wishlist else { return }
        do {
            try await client.share(id: entry.id, with: trimmed)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
