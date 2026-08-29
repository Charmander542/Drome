import AppIntents

struct WidgetTogglePlayIntent: AppIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WidgetCommandBridge.post(.togglePlay)
        return .result()
    }
}

struct WidgetNextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WidgetCommandBridge.post(.next)
        return .result()
    }
}

struct WidgetPreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WidgetCommandBridge.post(.previous)
        return .result()
    }
}

struct WidgetToggleLikeIntent: AppIntent {
    static var title: LocalizedStringResource = "Like Track"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WidgetCommandBridge.post(.toggleLike)
        return .result()
    }
}

struct WidgetToggleOutOfRotationIntent: AppIntent {
    static var title: LocalizedStringResource = "Out of Rotation"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WidgetCommandBridge.post(.toggleOutOfRotation)
        return .result()
    }
}
