import Foundation

/// Reveals a long song list in chunks so the header / Play / Shuffle paint
/// before thousands of rows hit SwiftUI.
@MainActor
struct ProgressiveSongReveal {
    /// How many rows to show on first paint.
    static let initial = 50
    /// Extra rows each time the user approaches the end.
    static let page = 40

    /// Grow `visibleCount` toward `total` when the user hits the loading row.
    static func expand(visibleCount: inout Int, total: Int) {
        guard visibleCount < total else { return }
        visibleCount = min(total, visibleCount + page)
    }

    static func clampInitial(total: Int) -> Int {
        min(total, initial)
    }
}
