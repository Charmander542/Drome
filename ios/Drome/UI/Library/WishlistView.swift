import SwiftUI

struct WishlistView: View {
    @EnvironmentObject private var session: AppSession

    @State private var entries: [WishlistEntry] = []
    @State private var pasteURL = ""
    @State private var isLoading = false
    @State private var isAdding = false
    @State private var error: String?
    @State private var shareTarget: WishlistEntry?
    @State private var shareUsername = ""

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
    }

    private var list: some View {
        List {
            Section {
                HStack {
                    TextField("Paste Spotify track or album link", text: $pasteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task { await add() }
                    } label: {
                        if isAdding {
                            ProgressView()
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(DromeTheme.accent)
                        }
                    }
                    .disabled(isAdding || pasteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .listRowBackground(DromeTheme.elevated)
            } footer: {
                Text("Links are resolved on your companion server — the Spotify secret never reaches this device.")
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.subheadline)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                if entries.isEmpty {
                    Text("Nothing here yet. Paste a Spotify link above.")
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(Color.clear)
                }
                ForEach(entries) { entry in
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
                                .strikethrough(entry.acquired)
                            Text([entry.artist, entry.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(DromeTheme.muted)
                            if let sharedBy = entry.sharedBy {
                                Text("Shared by \(sharedBy)")
                                    .font(.caption2)
                                    .foregroundStyle(DromeTheme.accent)
                            }
                        }
                        Spacer()
                        if entry.kind == "album" {
                            Text("ALBUM")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(DromeTheme.muted)
                        }
                    }
                    .opacity(entry.acquired ? 0.55 : 1)
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
                                Label(entry.acquired ? "Uncheck" : "Got it",
                                      systemImage: entry.acquired ? "arrow.uturn.backward" : "checkmark")
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
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
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

    private func add() async {
        guard let client = session.wishlist else { return }
        let url = pasteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isAdding = true
        error = nil
        defer { isAdding = false }
        do {
            let entry = try await client.add(spotifyLink: url)
            entries.insert(entry, at: 0)
            pasteURL = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ entry: WishlistEntry) async {
        guard let client = session.wishlist else { return }
        try? await client.delete(id: entry.id)
        entries.removeAll { $0.id == entry.id }
    }

    private func toggleAcquired(_ entry: WishlistEntry) async {
        guard let client = session.wishlist else { return }
        let next = !entry.acquired
        try? await client.setAcquired(id: entry.id, acquired: next)
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].acquired = next
        }
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
