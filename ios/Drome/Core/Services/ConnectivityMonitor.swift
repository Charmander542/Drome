import Foundation
import Network

/// Watches path reachability so the UI can switch into an offline downloads mode,
/// and so the player can recover when Tailscale / Wi‑Fi / cellular flaps.
@MainActor
final class ConnectivityMonitor: ObservableObject {
    /// Last known path flags — readable from PlayerEngine without holding a ref.
    private(set) static var lastIsCellular = false
    private(set) static var lastIsExpensive = false
    private(set) static var lastIsOnline = true
    /// Interfaces currently satisfied (e.g. wifi, cellular, other).
    private(set) static var lastInterfaceSummary = "unknown"

    @Published private(set) var isOnline = true
    /// True when the satisfied path is cellular / expensive (hotspot, WWAN).
    @Published private(set) var isExpensive = false
    @Published private(set) var isCellular = false
    @Published private(set) var interfaceSummary = "unknown"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.drome.connectivity")
    private var offlineTask: Task<Void, Never>?
    /// Debounce wifi↔wifi+cell flaps so the player isn't spammed mid-track.
    private var onlineNotifyTask: Task<Void, Never>?
    private var lastStatus: NWPath.Status?
    private var lastSummary: String?
    private var lastPublishedCellular: Bool?
    private var lastPublishedSummary: String?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            let cellular = path.usesInterfaceType(.cellular)
            let summary = ConnectivityMonitor.summarizePath(path)
            Task { @MainActor [weak self] in
                self?.handlePath(
                    online: online,
                    expensive: expensive,
                    cellular: cellular,
                    summary: summary,
                    status: path.status)
            }
        }
        monitor.start(queue: queue)
    }

    private func handlePath(
        online: Bool,
        expensive: Bool,
        cellular: Bool,
        summary: String,
        status: NWPath.Status
    ) {
        let wasOnline = isOnline
        isExpensive = expensive
        isCellular = cellular
        interfaceSummary = summary
        Self.lastIsExpensive = expensive
        Self.lastIsCellular = cellular
        Self.lastInterfaceSummary = summary

        offlineTask?.cancel()
        offlineTask = nil

        if online {
            let regained = !wasOnline || lastStatus != .satisfied
            isOnline = true
            Self.lastIsOnline = true
            lastStatus = status
            lastSummary = summary

            let cellularChanged = lastPublishedCellular.map { $0 != cellular } ?? true
            let summaryChanged = lastPublishedSummary.map { $0 != summary } ?? true
            guard cellularChanged || summaryChanged || regained else { return }

            // Publish regain immediately so stalled playback can recover.
            // Debounce pure wifi↔cell interface flaps (~1s) — dual-stack
            // phones otherwise flip resilient mode several times a minute.
            onlineNotifyTask?.cancel()
            if regained {
                publishOnlinePath(
                    cellular: cellular,
                    expensive: expensive,
                    summary: summary,
                    regained: true)
            } else {
                onlineNotifyTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    // Re-read latest flags after the quiet period.
                    let latestCellular = self.isCellular
                    let latestExpensive = self.isExpensive
                    let latestSummary = self.interfaceSummary
                    let stillChanged =
                        self.lastPublishedCellular != latestCellular
                        || self.lastPublishedSummary != latestSummary
                    guard stillChanged else { return }
                    self.publishOnlinePath(
                        cellular: latestCellular,
                        expensive: latestExpensive,
                        summary: latestSummary,
                        regained: false)
                }
            }
            return
        }

        onlineNotifyTask?.cancel()
        onlineNotifyTask = nil

        // Brief grace so flaky handoffs don't yank the whole UI offline.
        DromeDiagnostics.logNetwork("path unsatisfied (\(summary)) — grace 1.2s")
        offlineTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            isOnline = false
            Self.lastIsOnline = false
            lastStatus = status
            lastPublishedCellular = cellular
            lastPublishedSummary = summary
            NotificationCenter.default.post(
                name: .dromeNetworkPathChanged, object: nil,
                userInfo: [
                    "cellular": cellular,
                    "expensive": expensive,
                    "summary": summary,
                    "regained": false,
                    "offline": true,
                ])
        }
    }

    private func publishOnlinePath(
        cellular: Bool,
        expensive: Bool,
        summary: String,
        regained: Bool
    ) {
        lastPublishedCellular = cellular
        lastPublishedSummary = summary
        DromeDiagnostics.logNetwork(
            "path \(summary) cellular=\(cellular) expensive=\(expensive) regained=\(regained)")
        NotificationCenter.default.post(
            name: .dromeNetworkPathChanged, object: nil,
            userInfo: [
                "cellular": cellular,
                "expensive": expensive,
                "summary": summary,
                "regained": regained,
            ])
    }

    /// Nonisolated — called from the NWPathMonitor queue.
    private nonisolated static func summarizePath(_ path: NWPath) -> String {
        var parts: [String] = []
        if path.usesInterfaceType(.wifi) { parts.append("wifi") }
        if path.usesInterfaceType(.cellular) { parts.append("cell") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("eth") }
        if path.usesInterfaceType(.other) { parts.append("other") }
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("constrained") }
        switch path.status {
        case .satisfied: break
        case .unsatisfied: parts.append("unsatisfied")
        case .requiresConnection: parts.append("requiresConnection")
        @unknown default: parts.append("unknown")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }

    deinit {
        monitor.cancel()
    }
}
