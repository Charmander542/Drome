import SwiftUI

private struct AppSessionKey: EnvironmentKey {
    static let defaultValue: AppSession? = nil
}

extension EnvironmentValues {
    var session: AppSession? {
        get { self[AppSessionKey.self] }
        set { self[AppSessionKey.self] = newValue }
    }
}

extension View {
    func dromeSession(_ session: AppSession) -> some View {
        self
            .environment(\.session, session)
            .environmentObject(session)
            .environmentObject(session.player)
            .environmentObject(session.ratings)
            .environmentObject(session.rotation)
            .environmentObject(session.downloads)
            .environmentObject(session.lyricsIndexer)
    }
}
