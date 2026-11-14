import Foundation
import Combine

/// Shared sleep timer for music and podcasts.
///
/// Lives behind Now Playing overflow menus — not a Settings toggle — so it stays
/// out of the way until you need it. Fires once: pauses whichever engine is
/// playing, then clears itself.
@MainActor
final class SleepTimerController: ObservableObject {
    static let presets = [5, 15, 30, 45, 60]

    @Published private(set) var endsAt: Date?
    @Published private(set) var selectedMinutes: Int?

    private var task: Task<Void, Never>?
    private var pauseMusic: (() -> Void)?
    private var pausePodcast: (() -> Void)?

    var isActive: Bool { endsAt != nil }

    /// Remaining time label for menus ("12 min left").
    var remainingLabel: String? {
        guard let endsAt else { return nil }
        let seconds = max(0, endsAt.timeIntervalSinceNow)
        let minutes = Int(ceil(seconds / 60))
        if minutes <= 1 { return "About 1 min left" }
        return "\(minutes) min left"
    }

    func bind(pauseMusic: @escaping () -> Void, pausePodcast: @escaping () -> Void) {
        self.pauseMusic = pauseMusic
        self.pausePodcast = pausePodcast
    }

    func schedule(minutes: Int) {
        guard minutes > 0 else {
            cancel()
            return
        }
        task?.cancel()
        selectedMinutes = minutes
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        endsAt = deadline
        task = Task { [weak self] in
            let nanos = UInt64(minutes) * 60 * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.fire()
            }
        }
        DromeDiagnostics.logPlayer("sleep timer → \(minutes)m")
    }

    func cancel() {
        task?.cancel()
        task = nil
        endsAt = nil
        selectedMinutes = nil
        DromeDiagnostics.logPlayer("sleep timer → off")
    }

    private func fire() {
        DromeDiagnostics.logPlayer("sleep timer fired → pause")
        pauseMusic?()
        pausePodcast?()
        task = nil
        endsAt = nil
        selectedMinutes = nil
    }
}
