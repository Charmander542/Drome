import Foundation
import Network

/// Watches path reachability so the UI can switch into an offline downloads mode.
@MainActor
final class ConnectivityMonitor: ObservableObject {
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.drome.connectivity")
    private var offlineTask: Task<Void, Never>?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handlePath(online: online)
            }
        }
        monitor.start(queue: queue)
    }

    private func handlePath(online: Bool) {
        offlineTask?.cancel()
        offlineTask = nil
        if online {
            isOnline = true
            return
        }
        // Brief grace so flaky handoffs don't yank the whole UI offline.
        offlineTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            isOnline = false
        }
    }

    deinit {
        monitor.cancel()
    }
}
