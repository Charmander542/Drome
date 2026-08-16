import SwiftUI

struct TVRootView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Group {
            if let session = env.session {
                TVTabView()
                    .dromeSession(session)
                    .id(session.id)
            } else {
                TVLoginView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: env.session?.id)
    }
}
