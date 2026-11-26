import SwiftUI

/// Streaming & Downloads page — Spotify-style quality tiers for offline storage.
struct SettingsStreamingView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var downloadQuality = PlaybackPreferences.downloadQuality
    @State private var wifiOnlyDownloads = PlaybackPreferences.wifiOnlyDownloads
    @State private var confirmRedownload = false

    var openDownloads: () -> Void

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { PlaybackPreferences.compressOnCellular },
                    set: { PlaybackPreferences.compressOnCellular = $0 }
                )) {
                    Text("Stream compressed on cellular")
                }
                .tint(DromeTheme.accent)

                Toggle(isOn: Binding(
                    get: { PlaybackPreferences.resilientRemoteStreaming },
                    set: { PlaybackPreferences.resilientRemoteStreaming = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resilient remote streaming")
                        Text("Prefer compressed, cacheable streams off your LAN (Tailscale / public URL).")
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(DromeTheme.accent)

                LabeledContent("Cellular quality") {
                    Text("\(PlaybackPreferences.cellularMaxBitRate) kbps")
                        .foregroundStyle(DromeTheme.accent)
                }
                LabeledContent("Remote quality") {
                    Text("\(PlaybackPreferences.remoteMaxBitRate) kbps")
                        .foregroundStyle(DromeTheme.accent)
                }

                Picker(selection: Binding(
                    get: { AudioFXPreferences.prefetchCount },
                    set: { AudioFXPreferences.prefetchCount = $0 }
                )) {
                    Text("2 tracks").tag(2)
                    Text("3 tracks").tag(3)
                    Text("5 tracks").tag(5)
                    Text("8 tracks").tag(8)
                } label: {
                    Text("Pre-cache upcoming")
                }
            } header: {
                Text("Streaming")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Picker(selection: $downloadQuality) {
                    ForEach(DownloadQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                } label: {
                    Text("Download quality")
                }
                .onChange(of: downloadQuality) { _, newValue in
                    PlaybackPreferences.downloadQuality = newValue
                }

                Text(downloadQuality.detail)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .listRowSeparator(.hidden)

                Toggle(isOn: $wifiOnlyDownloads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download over Wi‑Fi only")
                        Text("Pause offline sync on cellular data.")
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(DromeTheme.accent)
                .onChange(of: wifiOnlyDownloads) { _, newValue in
                    PlaybackPreferences.wifiOnlyDownloads = newValue
                }

                Toggle(isOn: Binding(
                    get: { AudioFXPreferences.autoDownloadStarred },
                    set: { AudioFXPreferences.autoDownloadStarred = $0 }
                )) {
                    Text("Auto-download starred")
                }
                .tint(DromeTheme.accent)
            } header: {
                Text("Downloads")
            } footer: {
                Text("New downloads use the selected quality. Existing offline files stay as-is until you remove them or re-download.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                storageBar
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))

                HStack {
                    Circle().fill(DromeTheme.accent).frame(width: 8, height: 8)
                    Text("Downloads")
                    Spacer()
                    Text(Formatters.fileSize(downloads.totalBytesUsed))
                        .foregroundStyle(DromeTheme.muted)
                }
                HStack {
                    Circle().fill(Color.white.opacity(0.35)).frame(width: 8, height: 8)
                    Text("Cached lyrics / art")
                    Spacer()
                    Text("On device")
                        .foregroundStyle(DromeTheme.muted)
                }

                Button(action: openDownloads) {
                    HStack {
                        Text("Manage downloads")
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(downloads.downloadedCount)")
                            .foregroundStyle(DromeTheme.muted)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.28))
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("drome.settings.tile.downloads")

                if downloads.downloadedCount > 0 {
                    Button {
                        confirmRedownload = true
                    } label: {
                        HStack {
                            Text("Re-download at \(downloadQuality.title)")
                            Spacer()
                            Text(Formatters.fileSize(downloads.totalBytesUsed))
                                .foregroundStyle(DromeTheme.muted)
                        }
                    }
                    .foregroundStyle(.white)
                }

                Button(role: .destructive) {
                    downloads.removeAll()
                } label: {
                    HStack {
                        Text("Remove downloads")
                        Spacer()
                        Text(Formatters.fileSize(downloads.totalBytesUsed))
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Compressed downloads are typically 10–20× smaller than lossless library files.")
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollIndicators(.hidden)
        .navigationTitle("Streaming & Downloads")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            "Re-download \(downloads.downloadedCount) tracks at \(downloadQuality.title)?",
            isPresented: $confirmRedownload,
            titleVisibility: .visible
        ) {
            Button("Re-download", role: .destructive) {
                downloads.redownloadAllAtCurrentQuality()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the current offline files and queues them again. Wi‑Fi recommended.")
        }
    }

    private var storageBar: some View {
        GeometryReader { geo in
            let downloadShare = min(1, max(0.04, CGFloat(downloads.totalBytesUsed) / 5_000_000_000))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(DromeTheme.accent)
                    .frame(width: max(8, geo.size.width * downloadShare))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}
