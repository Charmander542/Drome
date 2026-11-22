import SwiftUI

struct SettingsConnectionsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var path: NavigationPath

    @State private var wishlistURLText = ""
    @State private var savedMessage: String?

    private var companionPlaceholder: String {
        dynamicTypeSize.isAccessibilitySize
            ? "Companion URL"
            : "https://wishlist.example.com"
    }

    var body: some View {
        List {
            Section {
                Button {
                    path.append(SettingsView.Route.tvPairing)
                } label: {
                    row("Send to Apple TV", systemImage: "appletv")
                }
                .buttonStyle(.borderless)

                if session.connect != nil {
                    Button {
                        path.append(SettingsView.Route.connect)
                    } label: {
                        row(
                            session.connect?.isRemote == true ? "Playing elsewhere" : "Connect devices",
                            systemImage: "hifispeaker.2")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("drome.settings.tile.connect")
                }

                Toggle(isOn: Binding(
                    get: { session.account.allowSelfSigned },
                    set: { newValue in
                        var account = session.account
                        account.allowSelfSigned = newValue
                        env.accounts.update(account)
                        env.activate(account)
                    }
                )) {
                    Text("Allow self-signed certificate")
                }
                .tint(DromeTheme.accent)
            } header: {
                Text("Devices")
            }
            .listRowBackground(DromeTheme.elevated)

            Section {
                TextField(companionPlaceholder, text: $wishlistURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    saveWishlistURL()
                } label: {
                    Label("Save companion URL", systemImage: "checkmark.circle")
                }
                if let savedMessage {
                    Text(savedMessage)
                        .font(.caption)
                        .foregroundStyle(DromeTheme.accent)
                }
            } header: {
                Text("Wishlist companion")
            } footer: {
                Text("Powers Daily Mixes, Spotify wishlist downloads, and Connect. Leave empty for streaming-only mode.")
            }
            .listRowBackground(DromeTheme.elevated)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollIndicators(.hidden)
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            wishlistURLText = session.account.wishlistURL?.absoluteString ?? ""
        }
    }

    private func row(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .foregroundStyle(DromeTheme.accent)
                .frame(width: 28)
            Text(title)
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.28))
        }
    }

    private func saveWishlistURL() {
        var account = session.account
        let trimmed = wishlistURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            account.wishlistURL = nil
        } else {
            guard let url = ServerURLNormalization.normalize(trimmed) else {
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
