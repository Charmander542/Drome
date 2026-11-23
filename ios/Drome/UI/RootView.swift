import SwiftUI

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var accentStore = AccentStore.shared
    @State private var showOnboarding = false

    var body: some View {
        Group {
            if let session = env.session {
                MainTabView()
                    .dromeSession(session)
                    .environmentObject(env.podcastManager)
                    .environmentObject(env.podcastPlayer)
                    .environmentObject(env.sleepTimer)
                    .id(session.id)
                    .fullScreenCover(isPresented: $showOnboarding) {
                        OnboardingView(userKey: session.account.userKey) {
                            showOnboarding = false
                        }
                    }
                    .onAppear { evaluateOnboarding(for: session) }
                    .onChange(of: session.id) { _, _ in
                        evaluateOnboarding(for: session)
                    }
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: env.session?.id)
        // Live tint only — never remount the signed-in tree for accent changes
        // (that wiped Home/tabs and looked like a full server reload). Account
        // switches still remount via `.id(session.id)` above.
        .tint(accentStore.color)
        .environment(\.dromeAccent, accentStore.color)
        .dromeScreen()
        .task { SharePlayRuntime.shared.startListening() }
        .onReceive(NotificationCenter.default.publisher(for: .dromeReplayOnboarding)) { _ in
            guard let session = env.session else { return }
            OnboardingPreference.reset(userKey: session.account.userKey)
            showOnboarding = true
        }
    }

    private func evaluateOnboarding(for session: AppSession) {
        #if DEBUG
        // Pair with `-UITestPodcastMini` to land signed-in and force the tour
        // regardless of the per-account completion flag.
        if ProcessInfo.processInfo.arguments.contains("-UITestShowOnboarding") {
            showOnboarding = true
            return
        }
        #endif
        showOnboarding = !OnboardingPreference.hasCompleted(userKey: session.account.userKey)
    }
}

