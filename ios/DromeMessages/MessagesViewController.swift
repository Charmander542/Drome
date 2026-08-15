import Messages
import SwiftUI
import UIKit

final class MessagesViewController: MSMessagesAppViewController {
    private var host: UIHostingController<AnyView>?
    private let picker = SongPickerModel()
    private let bubblePlayer = BubblePlayer()
    private var coverById: [String: UIImage] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        picker.onPick = { [weak self] track in
            Task { await self?.insert(track) }
        }
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        render(conversation: conversation)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        if let conversation = activeConversation {
            render(conversation: conversation)
        }
    }

    override func willResignActive(with conversation: MSConversation) {
        super.willResignActive(with: conversation)
        bubblePlayer.stop()
    }

    /// Messages ignores `preferredContentSize` for live bubbles; this is what
    /// actually sets transcript height. Keep it a few points taller than the art.
    override func contentSizeThatFits(_ size: CGSize) -> CGSize {
        guard presentationStyle == .transcript else {
            return super.contentSizeThatFits(size)
        }
        let height: CGFloat = 64
        let width = min(max(size.width, 160), 260)
        return CGSize(width: width, height: min(size.height, height))
    }

    private func render(conversation: MSConversation) {
        if presentationStyle == .transcript, let message = conversation.selectedMessage {
            showTranscript(message)
        } else {
            view.backgroundColor = .black
            embed(SongPickerView(model: picker))
        }
    }

    private func showTranscript(_ message: MSMessage) {
        view.backgroundColor = .black
        let track = ShareTrack.from(url: message.url) ?? ShareTrack(
            id: "", title: message.url?.lastPathComponent ?? "Track",
            artist: "", album: "", coverArt: nil)
        let host = MessagesStore.serverHost()
        let messageHost = URLComponents(url: message.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "server" }?.value
        let canStream = host != nil && host?.caseInsensitiveCompare(messageHost ?? "") == .orderedSame
        if canStream, let client = picker.client, !track.id.isEmpty {
            bubblePlayer.load(url: client.streamURL(songId: track.id))
        } else {
            bubblePlayer.load(url: nil)
        }
        embed(TranscriptBubbleView(
            track: track,
            cover: coverById[track.id],
            canStream: canStream,
            player: bubblePlayer))
        preferredContentSize = CGSize(width: 260, height: 64)
        if coverById[track.id] == nil, let client = picker.client {
            Task {
                if let data = await client.coverJPEG(coverArt: track.coverArt),
                   let image = UIImage(data: data) {
                    coverById[track.id] = image
                    if presentationStyle == .transcript {
                        showTranscript(message)
                    }
                }
            }
        }
    }

    private func insert(_ track: ShareTrack) async {
        guard let conversation = activeConversation else { return }
        picker.isWorking = true
        defer { picker.isWorking = false }

        let client = picker.client
        let jpeg = await client?.coverJPEG(coverArt: track.coverArt)
        let image = CoverImage.uiImage(from: jpeg)
        if let image { coverById[track.id] = image }

        async let share = client?.createShareURL(track: track, coverJPEG: jpeg)
        let webURL = await share

        let template = MSMessageTemplateLayout()
        template.image = MessageCardImage.render(cover: image, title: track.title, artist: track.artist)

        let message = MSMessage(session: conversation.selectedMessage?.session ?? MSSession())
        message.layout = MSMessageLiveLayout(alternateLayout: template)
        message.summaryText = [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " — ")
        message.url = webURL ?? client?.payloadURL(track: track)

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conversation.insert(message) { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
            requestPresentationStyle(.compact)
        } catch {
            // Leave the picker up so they can retry.
        }
    }

    private func embed<V: View>(_ root: V) {
        host?.willMove(toParent: nil)
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        let next = UIHostingController(rootView: AnyView(root))
        next.view.backgroundColor = .black
        if presentationStyle == .transcript {
            next.safeAreaRegions = []
        }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        next.didMove(toParent: self)
        host = next
    }
}
