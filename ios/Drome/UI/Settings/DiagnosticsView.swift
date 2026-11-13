import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var logText = ""
    @State private var showCopied = false
    @State private var copiedKind = "Report"

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
                Text("When playback glitches, tap Copy report for Cursor and paste the whole block into chat — it includes device, route, network, live player state, and the event tail.")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                Button {
                    let report = DromeDiagnostics.copyReadyReport(player: player)
                    UIPasteboard.general.string = report
                    copiedKind = "Report"
                    showCopied = true
                    reload()
                } label: {
                    Label("Copy report for Cursor", systemImage: "doc.on.clipboard")
                }
                .fontWeight(.semibold)

                Button {
                    DromeDiagnostics.snapshotPlayer(player, note: "manual")
                    reload()
                } label: {
                    Label("Capture player snapshot", systemImage: "waveform.badge.plus")
                }

                Button {
                    UIPasteboard.general.string = logText
                    copiedKind = "Log"
                    showCopied = true
                } label: {
                    Label("Copy raw log only", systemImage: "doc.on.doc")
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
        .alert("\(copiedKind) copied", isPresented: $showCopied) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(copiedKind == "Report"
                 ? "Paste the whole block into Cursor."
                 : "Raw event log is on the clipboard.")
        }
        .preferredColorScheme(.dark)
    }

    private func reload() {
        DromeDiagnostics.flush()
        logText = DromeDiagnostics.recentText
    }
}
