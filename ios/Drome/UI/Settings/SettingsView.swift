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
    @State private var isScanning = false
    @State private var scanMessage: String?
    @State private var scanFailed = false
    @AppStorage(LaunchIntroPreference.hapticKey) private var hapticIntro = false

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("User", value: session.account.username)
                LabeledContent("Server", value: session.account.serverURL.absoluteString)
                NavigationLink {
                    TVPairingView()
                } label: {
                    Label("Send to Apple TV", systemImage: "appletv")
                }
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
                Text("Companion server for Spotify wishlist downloads and Drome Connect (play on another phone or Apple TV). Example: http://host:4534")
            }
            .listRowBackground(DromeTheme.elevated)

            if let connect = session.connect {
                Section {
                    NavigationLink {
                        ConnectDevicePicker(connect: connect)
                    } label: {
                        Label(
                            connect.isRemote
                                ? "Playing elsewhere"
                                : "Connect devices",
                            systemImage: "hifispeaker.2"
                        )
                    }
                    LabeledContent("This device", value: connect.deviceName)
                    LabeledContent("Online", value: "\(max(connect.devices.count, 1))")
                } header: {
                    Text("Connect")
                } footer: {
                    Text("Same login on another Drome app. Tap a device to move playback there.")
                }
                .listRowBackground(DromeTheme.elevated)
            }

            Section {
                Toggle("Haptic intro", isOn: $hapticIntro)
            } header: {
                Text("Launch")
            } footer: {
                Text("Replaces the boot sound with a vibration timed to the same drum hits.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section("Playback") {
                Toggle("Autoplay / Infinite Shuffle", isOn: $player.autoplayEnabled)
                Toggle("Skip low-rated songs everywhere", isOn: Binding(
                    get: { PlaybackPreferences.skipLowRatedEverywhere },
                    set: { PlaybackPreferences.skipLowRatedEverywhere = $0 }
                ))
                Picker("Default shuffle", selection: Binding(
                    get: { player.shuffleMode },
                    set: { player.shuffleMode = $0 }
                )) {
                    Text("Off").tag(ShuffleMode.off)
                    Text("Smart (rating-weighted)").tag(ShuffleMode.smart)
                    Text("Random").tag(ShuffleMode.random)
                }
                Picker("Autoplay recency exclusion", selection: Binding(
                    get: { Int(PlaybackPreferences.autoplayRecencyHours) },
                    set: { PlaybackPreferences.autoplayRecencyHours = Double($0) }
                )) {
                    Text("24 hours").tag(24)
                    Text("3 days").tag(72)
                    Text("7 days").tag(168)
                    Text("30 days").tag(720)
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
                Button {
                    Task { await refreshLibrary() }
                } label: {
                    HStack {
                        Label("Refresh Library", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if isScanning {
                            ProgressView()
                        }
                    }
                }
                .disabled(isScanning)
                if let scanMessage {
                    Text(scanMessage)
                        .font(.caption)
                        .foregroundStyle(scanFailed ? Color.red.opacity(0.9) : DromeTheme.accent)
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Triggers a Navidrome library rescan on the server, then reloads local lists.")
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

    private func refreshLibrary() async {
        isScanning = true
        scanFailed = false
        scanMessage = "Starting scan…"
        defer { isScanning = false }
        do {
            try await session.client.startScan()
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 500_000_000)
                let status = try await session.client.scanStatus()
                if status.scanning == true {
                    let count = status.count.map(String.init) ?? "…"
                    scanMessage = "Scanning… \(count) items"
                } else {
                    let count = status.count.map(String.init) ?? "…"
                    scanMessage = "Scan complete (\(count) items)"
                    scanFailed = false
                    return
                }
            }
            scanMessage = "Scan still running on the server"
        } catch {
            scanFailed = true
            scanMessage = error.localizedDescription
        }
    }
}
