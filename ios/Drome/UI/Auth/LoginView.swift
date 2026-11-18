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
    /// Extra bottom padding for the Sign In chrome while the keyboard is up.
    /// Measured as keyboard overlap minus the home-indicator inset already
    /// applied by layout, so username/password QuickType bars can't cover it.
    @State private var keyboardFooterPadding: CGFloat = 0
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

                        // Tappable clear space so users can dismiss the keyboard
                        // without fighting the field hit targets above.
                        Color.clear
                            .frame(minHeight: 120)
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
            // Handle keyboard overlap ourselves so username/password autofill
            // bars (taller than the URL keyboard) can't cover Sign In.
            .ignoresSafeArea(.keyboard, edges: .bottom)
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
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification
            )) { notification in
                updateKeyboardFooterPadding(from: notification)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )) { notification in
                let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
                    ?? 0.25
                withAnimation(.easeOut(duration: duration)) {
                    keyboardFooterPadding = 0
                }
            }
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
            // Lift the actions by the live keyboard overlap (keys + Done +
            // autofill). Background fills that gap so content doesn't show through.
            .padding(.bottom, keyboardFooterPadding)
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
            HStack(spacing: 8) {
                if isWorking { ProgressView().tint(.black) }
                Text(isWorking ? "Connecting…" : "Sign In")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
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

    private func updateKeyboardFooterPadding(from notification: Notification) {
        guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        // Convert to the key window so overlap includes the Done accessory and
        // any username/password QuickType bar above the keys. Subtract the
        // window's bottom safe inset — `safeAreaInset` already clears that.
        let padding: CGFloat
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
            let converted = window.convert(frame, from: nil)
            let overlap = max(0, window.bounds.maxY - converted.minY)
            padding = max(0, overlap - window.safeAreaInsets.bottom)
        } else {
            padding = max(0, UIScreen.main.bounds.height - frame.minY)
        }
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
            ?? 0.25
        withAnimation(.easeOut(duration: duration)) {
            keyboardFooterPadding = padding
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
