import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var serverURL = "http://"
    @State private var username = ""
    @State private var password = ""
    @State private var wishlistURL = ""
    @State private var allowSelfSigned = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showSavedAccounts = false
    @State private var signInTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case server, user, password, wishlist
    }

    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = nil }

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
                            labeledField(
                                title: "Server URL",
                                text: $serverURL,
                                field: .server,
                                keyboard: .URL,
                                autocapitalization: .never,
                                contentType: .URL,
                                submitLabel: .next,
                                placeholder: "https://host:4533"
                            )
                            labeledField(
                                title: "Username",
                                text: $username,
                                field: .user,
                                keyboard: .default,
                                autocapitalization: .never,
                                contentType: .username,
                                submitLabel: .next
                            )
                            labeledSecureField(
                                title: "Password",
                                text: $password,
                                submitLabel: .next
                            )
                            labeledField(
                                title: "Wishlist server (optional)",
                                text: $wishlistURL,
                                field: .wishlist,
                                keyboard: .URL,
                                autocapitalization: .never,
                                contentType: .URL,
                                submitLabel: .go,
                                placeholder: "http://host:4534"
                            )

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
                                .id("loginError")
                        }

                        // Room below the fields so a focused row can scroll up into
                        // the viewport above the sticky Sign In chrome.
                        Color.clear
                            .frame(minHeight: accessibilityLayout ? 180 : 120)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { focusedField = nil }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
                .onChange(of: focusedField) { _, newValue in
                    guard let newValue else { return }
                    scrollFieldIntoView(newValue, proxy: proxy)
                }
                .onChange(of: errorMessage) { _, newValue in
                    guard newValue != nil else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("loginError", anchor: .center)
                    }
                }
            }
            .background {
                DromeTheme.background
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = nil }
            }
            // Sticky Sign In chrome only — system keyboard safe area lifts it.
            // Do not manually pad by the full keyboard height (that collapsed the
            // form and overlapped the focused field).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                signInChrome
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showSavedAccounts) {
            AccountSwitcherSheet()
                .environmentObject(env)
                .presentationDetents([.medium, .large])
        }
        .onDisappear { cancelSignIn() }
    }

    private var signInChrome: some View {
        signInActions
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(
                DromeTheme.background
                    .opacity(0.96)
                    .ignoresSafeArea(edges: .bottom)
            )
    }

    @ViewBuilder
    private var signInActions: some View {
        let cancel = Button(role: .cancel, action: cancelSignIn) {
            Text("Cancel")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: accessibilityLayout ? .infinity : nil)
                .padding(.vertical, accessibilityLayout ? 14 : 0)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .controlSize(.large)
        .accessibilityLabel("Cancel sign in")

        let submit = Button(action: signIn) {
            submitLabel
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(DromeTheme.accent)
        .foregroundStyle(.black)
        .disabled(isWorking || !canSubmit)
        .accessibilityLabel(isWorking ? "Connecting" : "Sign In")

        // Side-by-side at default sizes; stack at AX so labels don't mid-word wrap.
        if isWorking && accessibilityLayout {
            VStack(spacing: 10) {
                cancel
                    .frame(maxWidth: .infinity)
                submit
            }
        } else {
            HStack(spacing: 12) {
                if isWorking { cancel }
                submit
            }
        }
    }

    @ViewBuilder
    private var submitLabel: some View {
        // At AX sizes, stack spinner + short title so "Connecting…" isn't
        // truncated mid-word to "Connectin…".
        if isWorking && accessibilityLayout {
            VStack(spacing: 6) {
                ProgressView().tint(.black)
                Text("Connecting")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 8) {
                if isWorking { ProgressView().tint(.black) }
                Text(isWorking ? "Connecting…" : "Sign In")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    /// Pin the focused field near the top of the remaining viewport (below the
    /// status bar, above the sticky Sign In chrome) after the keyboard settles.
    private func scrollFieldIntoView(_ field: Field, proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(field, anchor: UnitPoint(x: 0.5, y: 0.18))
            }
        }
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && normalizedURL(serverURL) != nil
    }

    private func labeledField(
        title: String,
        text: Binding<String>,
        field: Field,
        keyboard: UIKeyboardType,
        autocapitalization: TextInputAutocapitalization,
        contentType: UITextContentType?,
        submitLabel: SubmitLabel,
        placeholder: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(DromeTheme.muted)
                .accessibilityHidden(true)

            TextField("", text: text, prompt: Text(placeholder ?? title))
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .textContentType(contentType)
                .submitLabel(submitLabel)
                .padding(14)
                .background(DromeTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($focusedField, equals: field)
                .accessibilityLabel(title)
                .onSubmit { advanceFocus(from: field) }
        }
        .id(field)
    }

    private func labeledSecureField(
        title: String,
        text: Binding<String>,
        submitLabel: SubmitLabel
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(DromeTheme.muted)
                .accessibilityHidden(true)

            SecureField("", text: text, prompt: Text(title))
                .textContentType(.password)
                .submitLabel(submitLabel)
                .padding(14)
                .background(DromeTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($focusedField, equals: .password)
                .accessibilityLabel(title)
                .onSubmit { advanceFocus(from: .password) }
        }
        .id(Field.password)
    }

    private func advanceFocus(from field: Field) {
        switch field {
        case .server: focusedField = .user
        case .user: focusedField = .password
        case .password: focusedField = .wishlist
        case .wishlist:
            focusedField = nil
            if canSubmit && !isWorking { signIn() }
        }
    }

    private func signIn() {
        guard let server = normalizedURL(serverURL) else {
            errorMessage = "Enter a valid server URL, e.g. http://192.168.1.10:4533"
            return
        }
        let wishlist = wishlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : normalizedURL(wishlistURL)

        signInTask?.cancel()
        isWorking = true
        errorMessage = nil
        focusedField = nil

        let account = Account(
            serverURL: server,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            allowSelfSigned: allowSelfSigned,
            wishlistURL: wishlist
        )

        signInTask = Task {
            let client = SubsonicClient(account: account, password: password)
            do {
                try await client.ping()
                guard !Task.isCancelled else { return }
                env.signIn(account: account, password: password)
            } catch is CancellationError {
                // User cancelled; leave the form as-is.
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession surfaces task cancellation as URLError.cancelled.
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            if !Task.isCancelled {
                isWorking = false
            }
            signInTask = nil
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        isWorking = false
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
