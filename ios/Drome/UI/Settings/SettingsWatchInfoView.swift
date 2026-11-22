import SwiftUI

struct SettingsWatchInfoView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Control Drome from your wrist")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("When the iPhone is playing, the Watch app mirrors Now Playing, transport, volume, rating, and Song Radio. Open Play on the Watch to start a recent or playlist.")
                        .font(.subheadline)
                        .foregroundStyle(DromeTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                labelRow("Transport", detail: "Play, pause, previous, next")
                labelRow("Volume", detail: "Raise / lower iPhone media volume")
                labelRow("Rating", detail: "Tap the star to step 1–5★")
                labelRow("Song Radio", detail: "Instant Mix from the current track")
            } header: {
                Text("Controls")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Text("Standalone Watch streaming (phone left at home) is on the roadmap. The Watch app can already launch independently; audio still plays on the paired iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(DromeTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("On its own")
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollIndicators(.hidden)
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.large)
    }

    private func labelRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(.white)
            Text(detail)
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
        }
        .padding(.vertical, 2)
    }
}
