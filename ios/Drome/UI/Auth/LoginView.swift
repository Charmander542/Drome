import SwiftUI

/// Aura-inspired Connect screen: aurora wash, frosted icon fields, white Connect CTA.
struct LoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var serverURL = "https://"
    @State private var username = ""
    @State private var password = ""
    @State private var wishlistURL = ""
    @State private var allowSelfSigned = false
    @State private var showAdvanced = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showSavedAccounts = false
    @State private var signInTask: Task<Void, Never>?
    @State private var appeared = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case server, user, password, wishlist
    }

    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && normalizedURL(serverURL) != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                auroraBackground
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = nil }

                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                header
                                    .padding(.top, accessibilityLayout ? 28 : 48)
                                    .padding(.bottom, 20)

                                // Demo is the unauthenticated try-path — not on Home.
                                demoEntry
                                    .padding(.horizontal, 28)
                                    .padding(.bottom, 22)

                                formFields
                                    .padding(.horizontal, 28)

                                if isWorking {
                                    HStack(spacing: 10) {
                                        ProgressView().tint(.white)
                                        Text("Connecting…")
                                            .font(.callout)
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    .padding(.top, 20)
                                }

                                if let errorMessage {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.red)
                                        Text(errorMessage)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.85))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.horizontal, 28)
                                    .padding(.top, 16)
                                    .id("loginError")
                                }

                                advancedSection
                                    .padding(.horizontal, 28)
                                    .padding(.top, 18)

                                if !env.accounts.accounts.isEmpty {
                                    Button {
                                        showSavedAccounts = true
                                    } label: {
                                        Label("Saved accounts", systemImage: "person.2")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.white.opacity(0.65))
                                    }
                                    .padding(.top, 22)
                                    .accessibilityIdentifier("drome.login.saved-accounts")
                                }

                                Color.clear
                                    .frame(height: accessibilityLayout ? 160 : 96)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity)
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

                    connectChrome
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityIdentifier("drome.login.screen")
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSavedAccounts) {
            AccountSwitcherSheet()
                .environmentObject(env)
                .presentationDetents([.medium, .large])
                .accessibilityIdentifier("drome.accounts.sheet")
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) { appeared = true }
        }
        .onDisappear { cancelSignIn() }
    }

    // MARK: - Aurora

    private var auroraBackground: some View {
        ZStack {
            Color.black

            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Warm amber club wash — matches brand accent, not violet.
                let a = Color(red: 0.95, green: 0.55, blue: 0.18)
                let b = Color(red: 0.85, green: 0.35, blue: 0.12)
                let c = Color(red: 1.0, green: 0.72, blue: 0.35)

                ZStack {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [a.opacity(0.65), a.opacity(0.18), .clear],
                                center: .center, startRadius: 20, endRadius: 220
                            )
                        )
                        .frame(width: 440, height: 440)
                        .offset(
                            x: -80 + CGFloat(sin(t * 0.4)) * 30,
                            y: -200 + CGFloat(cos(t * 0.3)) * 25
                        )
                        .scaleEffect(appeared ? 1.12 + CGFloat(sin(t * 0.5)) * 0.05 : 0.6)

                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [b.opacity(0.45), b.opacity(0.12), .clear],
                                center: .center, startRadius: 30, endRadius: 200
                            )
                        )
                        .frame(width: 380, height: 380)
                        .offset(
                            x: 100 + CGFloat(cos(t * 0.35)) * 25,
                            y: 50 + CGFloat(sin(t * 0.45)) * 30
                        )
                        .scaleEffect(appeared ? 1.08 + CGFloat(cos(t * 0.4)) * 0.05 : 0.6)

                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [c.opacity(0.35), c.opacity(0.08), .clear],
                                center: .center, startRadius: 10, endRadius: 180
                            )
                        )
                        .frame(width: 360, height: 360)
                        .offset(
                            x: -40 + CGFloat(sin(t * 0.5)) * 20,
                            y: 250 + CGFloat(cos(t * 0.35)) * 20
                        )
                        .scaleEffect(appeared ? 1.15 + CGFloat(sin(t * 0.3)) * 0.06 : 0.6)

                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.12), .clear],
                                center: .center, startRadius: 10, endRadius: 150
                            )
                        )
                        .frame(width: 300, height: 300)
                        .offset(
                            x: CGFloat(cos(t * 0.6)) * 60,
                            y: -50 + CGFloat(sin(t * 0.4)) * 50
                        )
                        .scaleEffect(appeared ? 1.0 : 0.4)
                }
                .blur(radius: 65)
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 8) {
            if let icon = UIImage(named: "LaunchLogo") ?? Bundle.main.icon {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            }

            Text("DROME")
                .font(.system(size: accessibilityLayout ? 36 : 32, weight: .heavy, design: .default))
                .tracking(2)
                .foregroundStyle(.white)

            Text("Connect your Navidrome server, or try the public demo.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }

    /// Public playground entry — lives here (pre-session), not on Home.
    private var demoEntry: some View {
        Button {
            fillPublicDemo()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent)
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try the public demo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("demo.navidrome.org · streaming only")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityIdentifier("drome.login.try-demo")
    }

    private var formFields: some View {
        VStack(spacing: 14) {
            iconField(
                icon: "link",
                placeholder: "Server URL",
                text: $serverURL,
                field: .server,
                keyboard: .URL,
                contentType: .URL,
                submitLabel: .next
            )
            iconField(
                icon: "person",
                placeholder: "Username",
                text: $username,
                field: .user,
                keyboard: .default,
                contentType: .username,
                submitLabel: .next
            )
            iconSecureField(placeholder: "Password", text: $password)
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) { showAdvanced.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(showAdvanced ? "Hide options" : "More options")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(showAdvanced ? 180 : 0))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.45))
        }
        .buttonStyle(.plain)

        if showAdvanced {
            VStack(spacing: 14) {
                iconField(
                    icon: "heart",
                    placeholder: "Wishlist server (optional)",
                    text: $wishlistURL,
                    field: .wishlist,
                    keyboard: .URL,
                    contentType: .URL,
                    submitLabel: .go
                )
                Toggle(isOn: $allowSelfSigned) {
                    Text("Allow self-signed certificate")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .tint(DromeTheme.accent)
                .padding(.horizontal, 4)
            }
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var connectChrome: some View {
        VStack(spacing: 10) {
            if isWorking {
                Button(role: .cancel, action: cancelSignIn) {
                    Text("Cancel")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.12))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .accessibilityLabel("Cancel sign in")
            }

            Button(action: signIn) {
                Group {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView().tint(.black)
                            Text("Connecting…")
                                .font(.headline)
                        }
                    } else {
                        Text("Connect")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(canSubmit && !isWorking ? Color.white : Color.white.opacity(0.2))
                .foregroundStyle(canSubmit && !isWorking ? Color.black : Color.white.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(isWorking || !canSubmit)
            .accessibilityLabel(isWorking ? "Connecting" : "Sign In")
            .accessibilityIdentifier("drome.login.sign-in")
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.55), Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Fields

    private func iconField(
        icon: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        keyboard: UIKeyboardType,
        contentType: UITextContentType?,
        submitLabel: SubmitLabel
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 20)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.35)))
                .font(.body)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(contentType)
                .submitLabel(submitLabel)
                .foregroundStyle(.white)
                .tint(.white)
                .focused($focusedField, equals: field)
                .accessibilityLabel(placeholder)
                .onSubmit { advanceFocus(from: field) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .id(field)
    }

    private func iconSecureField(placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 20)
            SecureField("", text: text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.35)))
                .font(.body)
                .textContentType(.password)
                .submitLabel(.go)
                .foregroundStyle(.white)
                .tint(.white)
                .focused($focusedField, equals: .password)
                .accessibilityLabel(placeholder)
                .onSubmit { advanceFocus(from: .password) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .id(Field.password)
    }

    private func scrollFieldIntoView(_ field: Field, proxy: ScrollViewProxy) {
        let anchorY: CGFloat = (field == .wishlist && accessibilityLayout) ? 0.08 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(field, anchor: UnitPoint(x: 0.5, y: anchorY))
            }
        }
    }

    private func advanceFocus(from field: Field) {
        switch field {
        case .server: focusedField = .user
        case .user: focusedField = .password
        case .password:
            if showAdvanced {
                focusedField = .wishlist
            } else {
                focusedField = nil
                if canSubmit && !isWorking { signIn() }
            }
        case .wishlist:
            focusedField = nil
            if canSubmit && !isWorking { signIn() }
        }
    }

    private func fillPublicDemo() {
        serverURL = Account.publicDemoServerURL.absoluteString
        username = Account.publicDemoUsername
        password = Account.publicDemoPassword
        wishlistURL = ""
        allowSelfSigned = false
        showAdvanced = false
        errorMessage = nil
        signIn()
    }

    private func signIn() {
        guard let server = normalizedURL(serverURL) else {
            errorMessage = "Enter a valid server URL, e.g. http://192.168.1.10:4533"
            return
        }
        // Demo / streaming-only: never attach a companion URL.
        let isDemoHost = (server.host ?? "").lowercased() == "demo.navidrome.org"
        let wishlist = (!isDemoHost
                        && !wishlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? normalizedURL(wishlistURL)
            : nil

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
            } catch let urlError as URLError where urlError.code == .cancelled {
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
        ServerURLNormalization.normalize(raw)
    }
}

// MARK: - Bundle icon helper

private extension Bundle {
    var icon: UIImage? {
        if let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let last = files.last {
            return UIImage(named: last)
        }
        return nil
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
