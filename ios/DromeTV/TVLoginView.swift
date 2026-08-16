import SwiftUI

struct TVLoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var pairing = DromeTVPairingHost()
    @State private var manual = false
    @State private var serverURL = "http://"
    @State private var username = ""
    @State private var password = ""
    @State private var wishlistURL = ""
    @State private var allowSelfSigned = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            TVTheme.canvas.ignoresSafeArea()
            RadialGradient(
                colors: [TVTheme.accent.opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 40,
                endRadius: 900)
                .ignoresSafeArea()

            HStack(alignment: .center, spacing: 90) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Drome")
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                    Text("Sign in with iPhone")
                        .font(.system(size: 32, weight: .semibold))
                    Text("Open Drome on your iPhone, then Settings → Send to Apple TV. Enter the PIN on the right.")
                        .font(.title3)
                        .foregroundStyle(TVTheme.dim)
                        .frame(maxWidth: 520, alignment: .leading)
                }

                VStack(spacing: 26) {
                    if !env.accounts.accounts.isEmpty {
                        ForEach(env.accounts.accounts) { account in
                            Button {
                                env.activate(account)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Continue as \(account.username)")
                                        .font(.title3.weight(.semibold))
                                    Text(account.serverURL.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(TVTheme.dim)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(pairing.pin)
                        .font(.system(size: 92, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .kerning(14)

                    Text(pairing.status)
                        .font(.title3)
                        .foregroundStyle(TVTheme.dim)

                    Button(manual ? "Hide keyboard sign-in" : "Type on Apple TV instead") {
                        manual.toggle()
                    }
                    .buttonStyle(.plain)

                    if manual { manualForm }
                }
                .frame(maxWidth: 680)
            }
            .padding(80)
        }
        .onAppear { pairing.start() }
        .onDisappear { pairing.stop() }
    }

    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Server URL", text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
            TextField("Wishlist server (optional)", text: $wishlistURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Allow self-signed certificate", isOn: $allowSelfSigned)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            Button(isWorking ? "Connecting…" : "Sign In") { signIn() }
                .disabled(isWorking || !canSubmit)
        }
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && normalizedURL(serverURL) != nil
    }

    private func signIn() {
        guard let server = normalizedURL(serverURL) else {
            errorMessage = "Enter a valid server URL."
            return
        }
        let wishlist = wishlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : normalizedURL(wishlistURL)
        isWorking = true
        errorMessage = nil
        let account = Account(
            serverURL: server,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            allowSelfSigned: allowSelfSigned,
            wishlistURL: wishlist)
        Task {
            let client = SubsonicClient(account: account, password: password)
            do {
                try await client.ping()
                env.signIn(account: account, password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func normalizedURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard var components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty else { return nil }
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}
