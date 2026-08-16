import Messages
import SwiftUI
import UIKit

final class MessagesViewController: MSMessagesAppViewController {
    private var host: UIHostingController<AnyView>?
    private let picker = SongPickerModel()
    private let bubblePlayer = BubblePlayer()
    private var coverById: [String: UIImage] = [:]
    private let chrome = TranscriptChrome()
    private var didEmbedTranscript = false
    private var coverAttempted: Set<String> = []
    private var metaAttempted: Set<String> = []
    private var pendingHostURLs: [URL] = []
    private var isOpeningHost = false
    private var hostOpenExpands = 0

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
        if pendingHostURLs.isEmpty, let conversation = activeConversation {
            render(conversation: conversation)
        }
        if !pendingHostURLs.isEmpty {
            openPendingHost(stage: 0)
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
            didEmbedTranscript = false
            embed(SongPickerView(model: picker))
        }
    }

    private func showTranscript(_ message: MSMessage) {
        view.backgroundColor = .black
        var track = ShareTrack.from(url: message.url)
        if let parsed = track, (parsed.title.isEmpty || parsed.coverArt == nil),
           let cached = MessagesStore.cachedTrack(id: parsed.id) {
            track = ShareTrack(
                id: parsed.id,
                title: parsed.title.isEmpty ? cached.title : parsed.title,
                artist: parsed.artist.isEmpty ? cached.artist : parsed.artist,
                album: parsed.album.isEmpty ? cached.album : parsed.album,
                coverArt: parsed.coverArt ?? cached.coverArt)
        }
        if track == nil, let live = message.layout as? MSMessageLiveLayout,
           let template = live.alternateLayout as? MSMessageTemplateLayout,
           let caption = template.caption, !caption.isEmpty {
            track = ShareTrack(
                id: "", title: caption,
                artist: template.subcaption ?? "", album: "", coverArt: nil)
        }
        let resolved = track ?? ShareTrack(
            id: "",
            title: message.summaryText?.split(separator: "—").first
                .map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Track",
            artist: "", album: "", coverArt: nil)
        let host = MessagesStore.serverHost()
        let messageHost = URLComponents(url: message.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "server" }?.value
        let serverKnown = messageHost == nil || messageHost?.isEmpty == true
            || (host != nil && host?.caseInsensitiveCompare(messageHost ?? "") == .orderedSame)
        let canStream = picker.client != nil && !resolved.id.isEmpty && serverKnown
        if canStream, let client = picker.client {
            bubblePlayer.load(url: client.streamURL(songId: resolved.id))
        } else {
            bubblePlayer.load(url: nil)
        }
        chrome.track = resolved
        chrome.cover = coverById[resolved.id]
        chrome.canStream = canStream
        chrome.onOpenInDrome = { [weak self] in self?.openTrackInDrome(self?.chrome.track ?? resolved) }
        if !didEmbedTranscript {
            didEmbedTranscript = true
            embed(TranscriptBubbleView(chrome: chrome, player: bubblePlayer))
        }
        preferredContentSize = CGSize(width: 260, height: 64)

        let coverKey = resolved.coverArt ?? resolved.id
        if !resolved.id.isEmpty, coverById[resolved.id] == nil, !coverAttempted.contains(resolved.id),
           let client = picker.client {
            coverAttempted.insert(resolved.id)
            Task {
                var data = await client.coverJPEG(coverArt: coverKey)
                if data == nil, coverKey != resolved.id {
                    data = await client.coverJPEG(coverArt: resolved.id)
                }
                if let data, let image = UIImage(data: data) {
                    coverById[resolved.id] = image
                    if chrome.track.id == resolved.id {
                        chrome.cover = image
                    }
                }
            }
        }
        if !resolved.id.isEmpty,
           (resolved.title.isEmpty || resolved.title == "Track"),
           !metaAttempted.contains(resolved.id),
           let client = picker.client {
            metaAttempted.insert(resolved.id)
            Task {
                if let fetched = await client.song(id: resolved.id) {
                    MessagesStore.save(fetched)
                    if chrome.track.id == resolved.id {
                        chrome.track = fetched
                        chrome.canStream = picker.client != nil
                    }
                }
            }
        }
    }

    private func openTrackInDrome(_ track: ShareTrack) {
        guard !track.id.isEmpty else { return }
        MessagesStore.setPendingOpen(track)
        var comps = URLComponents()
        comps.scheme = "drome"
        comps.host = "track"
        comps.path = "/\(track.id)"
        comps.queryItems = [URLQueryItem(name: "song", value: track.id)]
        guard let url = comps.url else { return }
        pendingHostURLs = [url]
        hostOpenExpands = 0

        DromeOpenURL(url, from: view.window ?? self) { _ in }

        if presentationStyle == .transcript {
            isOpeningHost = true
            requestPresentationStyle(.compact)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.isOpeningHost = false
                self.openPendingHost(stage: 0)
            }
        } else {
            openPendingHost(stage: 0)
        }
    }

    /// Transcript live bubbles often have a nil `extensionContext`; Apple only
    /// guarantees `open` after compact/expanded. Do not treat `windowScene.open`
    /// as success — it returns immediately without launching the host app.
    private func openPendingHost(stage: Int) {
        let urls = pendingHostURLs
        guard !urls.isEmpty else { return }

        func succeed() {
            pendingHostURLs = []
            isOpeningHost = false
        }
        func failAndAdvance(_ next: Int) {
            DispatchQueue.main.async { self.openPendingHost(stage: next) }
        }

        switch stage {
        case 0:
            if let ctx = resolvedExtensionContext() {
                tryExtensionOpen(ctx, urls: urls) { ok in
                    if ok { succeed() } else { failAndAdvance(1) }
                }
            } else {
                openPendingHost(stage: 1)
            }
        case 1:
            tryApplicationOpen(urls: urls, start: view.window ?? self) { ok in
                if ok { succeed() } else { failAndAdvance(2) }
            }
        case 2:
            guard presentationStyle == .transcript, hostOpenExpands < 2 else {
                isOpeningHost = false
                return
            }
            hostOpenExpands += 1
            isOpeningHost = true
            requestPresentationStyle(.compact)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, !self.pendingHostURLs.isEmpty else { return }
                self.isOpeningHost = false
                self.openPendingHost(stage: 0)
            }
        default:
            isOpeningHost = false
        }
    }

    private func resolvedExtensionContext() -> NSExtensionContext? {
        var vc: UIViewController? = self
        while let current = vc {
            if let ctx = current.extensionContext { return ctx }
            vc = current.parent ?? current.presentingViewController
        }
        if let ctx = host?.extensionContext { return ctx }
        return nil
    }

    private func tryExtensionOpen(
        _ ctx: NSExtensionContext, urls: [URL], done: @escaping (Bool) -> Void
    ) {
        func next(_ i: Int) {
            guard i < urls.count else {
                done(false)
                return
            }
            ctx.open(urls[i]) { success in
                DispatchQueue.main.async {
                    if success { done(true) } else { next(i + 1) }
                }
            }
        }
        next(0)
    }

    private func tryApplicationOpen(
        urls: [URL], start: UIResponder, done: @escaping (Bool) -> Void
    ) {
        func next(_ i: Int) {
            guard i < urls.count else {
                done(false)
                return
            }
            DromeOpenURL(urls[i], from: start) { success in
                DispatchQueue.main.async {
                    if success { done(true) } else { next(i + 1) }
                }
            }
        }
        next(0)
    }

    private func insert(_ track: ShareTrack) async {
        guard let conversation = activeConversation else { return }
        picker.isWorking = true
        defer { picker.isWorking = false }

        let client = picker.client
        var image = coverById[track.id]
        if image == nil {
            let jpeg = await client?.coverJPEG(coverArt: track.coverArt ?? track.id)
            image = CoverImage.uiImage(from: jpeg)
            if let image { coverById[track.id] = image }
        }
        let template = MSMessageTemplateLayout()
        template.image = MessageCardImage.render(cover: image, title: track.title, artist: track.artist)

        let session = conversation.selectedMessage?.session ?? MSSession()
        let message = MSMessage(session: session)
        message.layout = MSMessageLiveLayout(alternateLayout: template)
        message.summaryText = [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " — ")
        message.url = client?.messageURL(track: track, shareURL: nil)
        MessagesStore.save(track)
        MessagesStore.setPendingOpen(track)

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
