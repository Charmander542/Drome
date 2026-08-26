import Foundation
import Network

/// Watches path reachability so the UI can switch into an offline downloads mode,
/// and so the player can flip cellular compression without waiting on AirPlay.
@MainActor
final class ConnectivityMonitor: ObservableObject {
    /// Last known path flags — readable from PlayerEngine without holding a ref.
    private(set) static var lastIsCellular = false
    private(set) static var lastIsExpensive = false

    @Published private(set) var isOnline = true
    /// True when the satisfied path is cellular / expensive (hotspot, WWAN).
    @Published private(set) var isExpensive = false
    @Published private(set) var isCellular = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.drome.connectivity")
    private var offlineTask: Task<Void, Never>?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in
                self?.handlePath(online: online, expensive: expensive, cellular: cellular)
            }
        }
        monitor.start(queue: queue)
    }

    private func handlePath(online: Bool, expensive: Bool, cellular: Bool) {
        // Only WWAN flips matter for stream format; isExpensive flaps constantly
        // on Low Data Mode and was spamming path-change notifications.
        let cellularChanged = isCellular != cellular
        isExpensive = expensive
        isCellular = cellular
        Self.lastIsExpensive = expensive
        Self.lastIsCellular = cellular

        offlineTask?.cancel()
        offlineTask = nil
        if online {
            isOnline = true
            if cellularChanged {
                NotificationCenter.default.post(
                    name: .dromeNetworkPathChanged, object: nil)
            }
            return
        }
        // Brief grace so flaky handoffs don't yank the whole UI offline.
        offlineTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            isOnline = false
            NotificationCenter.default.post(
                name: .dromeNetworkPathChanged, object: nil)
        }
    }

    deinit {
        monitor.cancel()
    }
}
