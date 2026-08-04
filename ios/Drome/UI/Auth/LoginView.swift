import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var serverURL = "http://"
    @State private var username = ""
    @State private var password = ""
    @State private var wishlistURL = ""
    @State private var allowSelfSigned = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showSavedAccounts = false
    @FocusState private var focusedField: Field?

    private enum Field { case server, user, password, wishlist }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Drome")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Stream your Navidrome library.")
                        .font(.title3)
                        .foregroundStyle(DromeTheme.muted)
                }
                .padding(.top, 48)

                if !env.accounts.accounts.isEmpty {
                    Button {
                        showSavedAccounts = true
                    } label: {
                        Label("Switch to a saved account", systemImage: "person.2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }

                VStack(spacing: 14) {
                    field("Server URL", text: $serverURL, field: .server,
                          keyboard: .URL, autocapitalization: .never)
                    field("Username", text: $username, field: .user,
                          keyboard: .default, autocapitalization: .never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding(14)
                        .background(DromeTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .focused($focusedField, equals: .password)
                    field("Wishlist server (optional)", text: $wishlistURL, field: .wishlist,
                          keyboard: .URL, autocapitalization: .never,
                          prompt: "http://host:4534")

                    Toggle(isOn: $allowSelfSigned) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow self-signed certificate")
                            Text("Only for your own Navidrome host.")
                                .font(.caption)
                                .foregroundStyle(DromeTheme.muted)
                        }
                    }
                    .tint(DromeTheme.accent)
                    .padding(.top, 4)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Button(action: signIn) {
                    HStack {
                        if isWorking { ProgressView().tint(.black) }
                        Text(isWorking ? "Connecting…" : "Sign In")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(DromeTheme.accent)
                .foregroundStyle(.black)
                .disabled(isWorking || !canSubmit)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showSavedAccounts) {
            AccountSwitcherSheet()
                .environmentObject(env)
                .presentationDetents([.medium, .large])
        }
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && normalizedURL(serverURL) != nil
    }

    private func field(_ title: String, text: Binding<String>, field: Field,
                       keyboard: UIKeyboardType, autocapitalization: TextInputAutocapitalization,
                       prompt: String? = nil) -> some View {
        TextField(title, text: text, prompt: prompt.map(Text.init))
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled()
            .textContentType(field == .user ? .username : .URL)
            .padding(14)
            .background(DromeTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focused($focusedField, equals: field)
    }

    private func signIn() {
        guard let server = normalizedURL(serverURL) else {
            errorMessage = "Enter a valid server URL, e.g. http://192.168.1.10:4533"
            return
        }
        let wishlist = wishlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : normalizedURL(wishlistURL)

        isWorking = true
        errorMessage = nil
        focusedField = nil

        let account = Account(
            serverURL: server,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            allowSelfSigned: allowSelfSigned,
            wishlistURL: wishlist
        )

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
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        guard var components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty else { return nil }
        // Strip trailing slash from path for cleaner Subsonic base URLs.
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}

struct AccountSwitcherSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(env.accounts.accounts) { account in
                    Button {
                        env.activate(account)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.username)
                                    .foregroundStyle(.white)
                                Text(account.serverURL.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                            Spacer()
                            if account.id == env.accounts.activeAccountID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DromeTheme.accent)
                            }
                        }
                    }
                    .listRowBackground(DromeTheme.elevated)
                }
                .onDelete { offsets in
                    for index in offsets {
                        env.remove(env.accounts.accounts[index])
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DromeTheme.background)
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
