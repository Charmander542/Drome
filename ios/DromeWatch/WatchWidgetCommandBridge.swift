import Foundation

enum WatchWidgetCommand: String, Codable {
    case togglePlay
    case next
    case previous

    var watchCommand: WatchCommand {
        switch self {
        case .togglePlay: return .togglePlay
        case .next: return .next
        case .previous: return .previous
        }
    }
}

/// App Group bridge for watch widget button taps → watch app → iPhone.
enum WatchWidgetCommandBridge {
    static let appGroupID = WatchWidgetStore.appGroupID
    private static let commandKey = "watch-widget-command"
    private static let notificationName = CFNotificationName("com.drome.watch.widget.command" as CFString)
    private static var observerBox: ObserverBox?
    private static var isObserving = false

    static func post(_ command: WatchWidgetCommand) {
        UserDefaults(suiteName: appGroupID)?.set(command.rawValue, forKey: commandKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            notificationName,
            nil, nil, true)
    }

    static func consume() -> WatchWidgetCommand? {
        guard let raw = UserDefaults(suiteName: appGroupID)?.string(forKey: commandKey),
              let command = WatchWidgetCommand(rawValue: raw)
        else { return nil }
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: commandKey)
        return command
    }

    static func startObserving(handler: @escaping (WatchWidgetCommand) -> Void) {
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
                if let command = WatchWidgetCommandBridge.consume() {
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
    var handler: (WatchWidgetCommand) -> Void
    init(handler: @escaping (WatchWidgetCommand) -> Void) { self.handler = handler }
}
