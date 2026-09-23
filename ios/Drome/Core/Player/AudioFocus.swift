import Foundation

/// Single in-app owner of audible playback.
///
/// Music and podcast each have their own `AVPlayer`. The shared `AVAudioSession`
/// does not serialize them — without an owner, Bluetooth interruptions and
/// stacked remote-command handlers can resume both at once.
@MainActor
enum AudioFocusOwner: Equatable {
    case none
    case music
    case podcast
}

@MainActor
final class AudioFocus {
    static let shared = AudioFocus()

    private(set) var owner: AudioFocusOwner = .none

    func claim(_ next: AudioFocusOwner) {
        guard next != .none else {
            owner = .none
            return
        }
        owner = next
    }

    func release(_ source: AudioFocusOwner) {
        if owner == source {
            owner = .none
        }
    }

    func isOwner(_ source: AudioFocusOwner) -> Bool {
        owner == source
    }
}
