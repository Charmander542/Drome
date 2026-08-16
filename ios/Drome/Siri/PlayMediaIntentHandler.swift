import Intents

/// Lets Siri route generic “Play …” requests to Drome when it is the default
/// music app, or when the user says “in Drome”.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(for intent: INPlayMediaIntent,
                           with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        Task { @MainActor in
            let query = Self.query(from: intent)
            guard !query.isEmpty else {
                completion([INPlayMediaMediaItemResolutionResult.needsValue()])
                return
            }
            if AppEnvironment.shared?.session == nil {
                completion([INPlayMediaMediaItemResolutionResult.unsupported(forReason: .loginRequired)])
                return
            }
            let items = await DromeSiriPlayback.resolveMediaItems(
                query: query,
                artist: intent.mediaSearch?.artistName,
                album: intent.mediaSearch?.albumName)
            if items.isEmpty {
                completion([INPlayMediaMediaItemResolutionResult.unsupported()])
                return
            }
            completion(items.map { INPlayMediaMediaItemResolutionResult.success(with: $0) })
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        Task { @MainActor in
            let items = intent.mediaItems ?? []
            let outcome = await DromeSiriPlayback.handle(mediaItems: items)
            let code: INPlayMediaIntentResponseCode
            switch outcome {
            case .played, .wishlisted:
                code = .success
            case .notSignedIn:
                code = .failureRequiringAppLaunch
            default:
                code = .failure
            }
            completion(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
    }

    private static func query(from intent: INPlayMediaIntent) -> String {
        if let name = intent.mediaSearch?.mediaName, !name.isEmpty { return name }
        if let item = intent.mediaItems?.first, let title = item.title, !title.isEmpty { return title }
        if let artist = intent.mediaSearch?.artistName, !artist.isEmpty { return artist }
        if let album = intent.mediaSearch?.albumName, !album.isEmpty { return album }
        return ""
    }
}
