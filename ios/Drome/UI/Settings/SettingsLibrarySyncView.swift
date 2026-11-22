import SwiftUI

struct SettingsLibrarySyncView: View {
    @EnvironmentObject private var session: AppSession

    @State private var isScanning = false
    @State private var scanMessage: String?
    @State private var scanFailed = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { LibraryArtistFilter.hideCreditOnlyArtists },
                    set: { LibraryArtistFilter.hideCreditOnlyArtists = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide feature credits")
                        Text("Removes artists with no albums who only appear on other people’s tracks.")
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(DromeTheme.accent)
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Button {
                    Task { await refreshLibrary() }
                } label: {
                    HStack {
                        Text("Refresh library")
                            .foregroundStyle(.white)
                        Spacer()
                        if isScanning {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isScanning)
                .accessibilityIdentifier("drome.settings.tile.online")

                if let scanMessage {
                    Text(scanMessage)
                        .font(.caption)
                        .foregroundStyle(scanFailed ? Color.red.opacity(0.9) : DromeTheme.accent)
                }
            } header: {
                Text("Navidrome scan")
            } footer: {
                Text("Asks your server to rescan the music folder, then pull fresh lists into Drome.")
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollIndicators(.hidden)
        .navigationTitle("Library sync")
        .navigationBarTitleDisplayMode(.large)
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
