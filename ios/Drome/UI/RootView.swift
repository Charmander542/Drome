import SwiftUI

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Group {
            if let session = env.session {
                MainTabView()
                    .dromeSession(session)
                    .id(session.id)
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: env.session?.id)
        .dromeScreen()
        .task { SharePlayRuntime.shared.startListening() }
    }
}

