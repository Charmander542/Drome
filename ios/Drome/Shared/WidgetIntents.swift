import AppIntents
import WidgetKit

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

struct WidgetSelectVibeIntent: AppIntent {
    static var title: LocalizedStringResource = "Select Vibe"
    static var openAppWhenRun = false

    @Parameter(title: "Vibe")
    var vibeID: String

    init() {
        vibeID = MoodVibe.hype.rawValue
    }

    init(vibeID: String) {
        self.vibeID = vibeID
    }

    func perform() async throws -> some IntentResult {
        if let vibe = MoodVibe(rawValue: vibeID) {
            WidgetVibeStore.selectedVibe = vibe
            WidgetCenter.shared.reloadTimelines(ofKind: "VibeTunerWidget")
        }
        return .result()
    }
}

struct WidgetPlayVibeIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Vibe"
    static var openAppWhenRun = true

    @Parameter(title: "Vibe")
    var vibeID: String?

    init() {}

    init(vibeID: String?) {
        self.vibeID = vibeID
    }

    func perform() async throws -> some IntentResult {
        let id = vibeID ?? WidgetVibeStore.selectedVibe.rawValue
        WidgetCommandBridge.postPlayVibe(id)
        return .result()
    }
}
