import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var logText = ""
    @State private var showCopied = false

    var body: some View {
        List {
            Section {
                ScrollView {
                    Text(logText.isEmpty ? "No events yet." : logText)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 280)
            } header: {
                Text("Recent events")
            } footer: {
                Text("A rolling log of playback and app events. After a crash, reopen Drome and copy or share this log — it helps trace what happened right before.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Button {
                    DromeDiagnostics.snapshotPlayer(player, note: "manual")
                    reload()
                } label: {
                    Label("Capture player snapshot", systemImage: "waveform.badge.plus")
                }

                Button {
                    UIPasteboard.general.string = logText
                    showCopied = true
                } label: {
                    Label("Copy log", systemImage: "doc.on.doc")
                }

                ShareLink(item: DromeDiagnostics.logFileURL) {
                    Label("Share log file", systemImage: "square.and.arrow.up")
                }

                Button("Clear log", role: .destructive) {
                    DromeDiagnostics.clearLog()
                    reload()
                }
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Text("iOS also saves crash reports under Settings → Privacy & Security → Analytics & Improvements → Analytics Data (look for Drome). Xcode → Window → Devices and Simulators → View Device Logs shows the same .ips files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .scrollContentBackground(.hidden)
        .background(DromeTheme.background)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .alert("Copied", isPresented: $showCopied) {
            Button("OK", role: .cancel) { }
        }
        .preferredColorScheme(.dark)
    }

    private func reload() {
        DromeDiagnostics.flush()
        logText = DromeDiagnostics.recentText
    }
}
