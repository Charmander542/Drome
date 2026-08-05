import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var lyricsIndexer: LyricsIndexer
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    @State private var wishlistURLText = ""
    @State private var savedMessage: String?

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("User", value: session.account.username)
                LabeledContent("Server", value: session.account.serverURL.absoluteString)
                Toggle("Allow self-signed cert", isOn: Binding(
                    get: { session.account.allowSelfSigned },
                    set: { newValue in
                        var account = session.account
                        account.allowSelfSigned = newValue
                        env.accounts.update(account)
                        env.activate(account)
                    }
                ))
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                TextField("http://host:4534", text: $wishlistURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Save Wishlist Server") {
                    saveWishlistURL()
                }
                if let savedMessage {
                    Text(savedMessage).font(.caption).foregroundStyle(DromeTheme.accent)
                }
            } header: {
                Text("Wishlist companion")
            } footer: {
                Text("Optional Go service for Spotify search + wishlist downloads into your Navidrome library. Set URL to http://host:4534")
            }
            .listRowBackground(DromeTheme.elevated)

            Section("Playback") {
                Toggle("Autoplay / Infinite Shuffle", isOn: $player.autoplayEnabled)
                Picker("Default shuffle", selection: Binding(
                    get: { player.shuffleMode },
                    set: { player.shuffleMode = $0 }
                )) {
                    Text("Off").tag(ShuffleMode.off)
                    Text("Smart (rating-weighted)").tag(ShuffleMode.smart)
                    Text("Random").tag(ShuffleMode.random)
                }
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Toggle("Background lyrics indexer", isOn: Binding(
                    get: { lyricsIndexer.isEnabled },
                    set: { lyricsIndexer.isEnabled = $0 }
                ))
                LabeledContent("Cached lyrics", value: "\(lyricsIndexer.cachedCount)")
                if lyricsIndexer.isRunning {
                    LabeledContent("Status", value: lyricsIndexer.statusText)
                }
                Button("Reindex from start") {
                    lyricsIndexer.reindexFromStart()
                }
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Progressively fetches lyrics (Navidrome first, LRCLIB fallback) so Deep Search can find songs by half-remembered lines.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section("Storage") {
                LabeledContent("Downloads", value: Formatters.fileSize(downloads.totalBytesUsed))
                NavigationLink("Manage downloads") {
                    DownloadsView()
                }
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Button("Sign Out", role: .destructive) {
                    env.signOut()
                    dismiss()
                }
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .scrollContentBackground(.hidden)
        .background(DromeTheme.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            wishlistURLText = session.account.wishlistURL?.absoluteString ?? ""
        }
        .preferredColorScheme(.dark)
    }

    private func saveWishlistURL() {
        var account = session.account
        let trimmed = wishlistURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            account.wishlistURL = nil
        } else {
            var raw = trimmed
            if !raw.contains("://") { raw = "http://" + raw }
            guard let url = URL(string: raw), url.host != nil else {
                savedMessage = "Invalid URL"
                return
            }
            account.wishlistURL = url
        }
        env.accounts.update(account)
        env.activate(account)
        savedMessage = "Saved"
    }
}
