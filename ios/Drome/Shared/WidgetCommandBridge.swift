import Foundation

enum WidgetCommand: String, Codable {
    case togglePlay
    case next
    case previous
    case toggleLike
    case toggleOutOfRotation
}

/// App Group bridge for widget button taps → main app playback.
enum WidgetCommandBridge {
    static let appGroupID = WidgetRecentStore.appGroupID
    private static let commandKey = "widget-command"
    private static let notificationName = CFNotificationName("com.drome.widget.command" as CFString)
    private static var observerBox: ObserverBox?
    private static var isObserving = false

    static func post(_ command: WidgetCommand) {
        UserDefaults(suiteName: appGroupID)?.set(command.rawValue, forKey: commandKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            notificationName,
            nil, nil, true)
    }

    static func consume() -> WidgetCommand? {
        guard let raw = UserDefaults(suiteName: appGroupID)?.string(forKey: commandKey),
              let command = WidgetCommand(rawValue: raw)
        else { return nil }
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: commandKey)
        return command
    }

    static func startObserving(handler: @escaping (WidgetCommand) -> Void) {
        if let observerBox {
            observerBox.handler = handler
        } else {
            observerBox = ObserverBox(handler: handler)
        }
        guard !isObserving, let box = observerBox else { return }
        isObserving = true
        let pointer = Unmanaged.passUnretained(box).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            pointer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let box = Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue()
                if let command = WidgetCommandBridge.consume() {
                    DispatchQueue.main.async { box.handler(command) }
                }
            },
            notificationName.rawValue,
            nil,
            .deliverImmediately)
    }

    static func stopObserving() {
        guard isObserving, let box = observerBox else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(box).toOpaque(),
            notificationName,
            nil)
        isObserving = false
    }
}

private final class ObserverBox {
    var handler: (WidgetCommand) -> Void
    init(handler: @escaping (WidgetCommand) -> Void) { self.handler = handler }
}
