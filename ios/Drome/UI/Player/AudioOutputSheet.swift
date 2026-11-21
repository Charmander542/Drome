import SwiftUI

/// Half-sheet device picker — Drome Connect when available, otherwise system AirPlay.
struct AudioOutputSheet: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let connect = session.connect {
                ConnectDevicePicker(connect: connect)
            } else {
                airPlayOnly
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(DromeTheme.background)
    }

    private var airPlayOnly: some View {
        NavigationStack {
            List {
                Section {
                    ZStack(alignment: .leading) {
                        HStack(spacing: 14) {
                            Image(systemName: "airplayaudio")
                                .font(.title2)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AirPlay & Bluetooth")
                                Text("Speakers, TVs, and headphones")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .allowsHitTesting(false)
                        AirPlayRoutePicker(tintColor: .clear, activeTintColor: .clear)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .listRowBackground(DromeTheme.elevated)
                } footer: {
                    Text("Set a companion server in Settings to also move playback between Drome apps.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DromeTheme.background)
            .navigationTitle("Audio output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .tint(.white)
            .toolbarBackground(DromeTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
