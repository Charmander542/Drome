import SwiftUI

struct SettingsHomeNetworkView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession

    @State private var homeURLText = ""
    @State private var customHeadersText = ""
    @State private var networkSavedMessage: String?

    var body: some View {
        List {
            Section {
                TextField("Home / LAN URL (optional)", text: $homeURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Custom headers (Header: value per line)", text: $customHeadersText, axis: .vertical)
                    .font(.caption.monospaced())
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    saveNetworkSettings()
                } label: {
                    Label("Save", systemImage: "network")
                }
                if let networkSavedMessage {
                    Text(networkSavedMessage)
                        .font(.caption)
                        .foregroundStyle(DromeTheme.accent)
                }
            } header: {
                Text("Home / Away")
            } footer: {
                Text("When a home URL is set, Drome prefers it on your LAN. Custom headers help with Cloudflare Access and reverse proxies.")
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollIndicators(.hidden)
        .navigationTitle("Home network")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            homeURLText = session.account.homeURL?.absoluteString ?? ""
            customHeadersText = session.account.customHeaders
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        }
    }

    private func saveNetworkSettings() {
        var account = session.account
        let homeTrimmed = homeURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if homeTrimmed.isEmpty {
            account.homeURL = nil
        } else if let url = ServerURLNormalization.normalize(homeTrimmed) {
            account.homeURL = url
        } else {
            networkSavedMessage = "Invalid home URL"
            return
        }
        var headers: [String: String] = [:]
        for line in customHeadersText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            headers[parts[0]] = parts[1]
        }
        account.customHeaders = headers
        env.accounts.update(account)
        env.activate(account)
        if let home = account.homeURL {
            session.client.setBaseURL(home)
        } else {
            session.client.setBaseURL(account.serverURL)
        }
        networkSavedMessage = "Saved"
        Task { await ServerReachability.probeAndSelect(client: session.client, account: account) }
    }
}
