import AppIntents

struct WatchWidgetTogglePlayIntent: AppIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WatchWidgetCommandBridge.post(.togglePlay)
        return .result()
    }
}

struct WatchWidgetNextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WatchWidgetCommandBridge.post(.next)
        return .result()
    }
}

struct WatchWidgetPreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WatchWidgetCommandBridge.post(.previous)
        return .result()
    }
}
