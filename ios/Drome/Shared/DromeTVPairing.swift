import Foundation
import Network

/// Local-network pairing so an iPhone already signed into Drome can send
/// Navidrome credentials to Apple TV. Same Wi-Fi; PIN is shown only on the TV.
enum DromeTVPairing {
    static let serviceType = "_drome-pair._tcp"

    struct Credentials: Codable {
        var pin: String
        var serverURL: String
        var username: String
        var password: String
        var wishlistURL: String?
        var allowSelfSigned: Bool
    }

    struct Reply: Codable {
        var ok: Bool
        var error: String?
    }

    static func makePIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func tcpParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let options = NWProtocolTCP.Options()
        options.enableFastOpen = false
        parameters.defaultProtocolStack.transportProtocol = options
        return parameters
    }
}

enum DromeTVPairingIO {
    static func send(_ value: some Encodable, on connection: NWConnection) async throws {
        let data = try JSONEncoder().encode(value)
        var length = UInt32(data.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    static func receive<T: Decodable>(_ type: T.Type, on connection: NWConnection) async throws -> T {
        let header = try await receiveExact(4, on: connection)
        let length = header.withUnsafeBytes { ptr in
            UInt32(bigEndian: ptr.load(as: UInt32.self))
        }
        guard length > 0, length < 256_000 else {
            throw PairingError.badMessage
        }
        let body = try await receiveExact(Int(length), on: connection)
        return try JSONDecoder().decode(T.self, from: body)
    }

    private static func receiveExact(_ count: Int, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let content, content.count == count {
                    cont.resume(returning: content)
                } else {
                    cont.resume(throwing: PairingError.badMessage)
                }
            }
        }
    }

    enum PairingError: LocalizedError {
        case badMessage
        case wrongPIN
        case noPassword
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .badMessage: return "Couldn’t read the pairing message."
            case .wrongPIN: return "That PIN doesn’t match the Apple TV."
            case .noPassword: return "Sign in on iPhone first so Drome can send the password."
            case .failed(let message): return message
            }
        }
    }
}

#if os(tvOS)
@MainActor
final class DromeTVPairingHost: ObservableObject {
    @Published private(set) var pin: String
    @Published var status: String = "Waiting for iPhone…"

    var onSignedIn: (() -> Void)?

    private var listener: NWListener?
    private var connections: [NWConnection] = []

    init() {
        pin = DromeTVPairing.makePIN()
    }

    func start() {
        stop()
        pin = DromeTVPairing.makePIN()
        status = "Waiting for iPhone…"
        do {
            let listener = try NWListener(using: DromeTVPairing.tcpParameters())
            listener.service = NWListener.Service(name: "Drome", type: DromeTVPairing.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.status = "Waiting for iPhone…"
                    case .failed(let error):
                        self?.status = error.localizedDescription
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handle(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        Task {
            defer {
                connection.cancel()
                connections.removeAll { $0 === connection }
            }
            do {
                let creds = try await DromeTVPairingIO.receive(DromeTVPairing.Credentials.self, on: connection)
                guard creds.pin == pin else {
                    try await DromeTVPairingIO.send(DromeTVPairing.Reply(ok: false, error: "Wrong PIN"), on: connection)
                    status = "Wrong PIN — try again"
                    pin = DromeTVPairing.makePIN()
                    return
                }
                status = "Signing in…"
                guard let server = URL(string: creds.serverURL) else {
                    try await DromeTVPairingIO.send(DromeTVPairing.Reply(ok: false, error: "Invalid server URL"), on: connection)
                    return
                }
                let wishlist = creds.wishlistURL.flatMap(URL.init(string:))
                let account = Account(
                    serverURL: server,
                    username: creds.username,
                    allowSelfSigned: creds.allowSelfSigned,
                    wishlistURL: wishlist)
                let client = SubsonicClient(account: account, password: creds.password)
                try await client.ping()
                AppEnvironment.shared.signIn(account: account, password: creds.password)
                try await DromeTVPairingIO.send(DromeTVPairing.Reply(ok: true, error: nil), on: connection)
                onSignedIn?()
            } catch {
                status = error.localizedDescription
                try? await DromeTVPairingIO.send(
                    DromeTVPairing.Reply(ok: false, error: error.localizedDescription),
                    on: connection)
            }
        }
    }
}
#endif

#if os(iOS)
@MainActor
final class DromeTVPairingClient: ObservableObject {
    struct FoundTV: Identifiable, Hashable {
        var id: String
        var name: String
        var endpoint: NWEndpoint
    }

    @Published var televisions: [FoundTV] = []
    @Published var status: String = "Looking for Apple TV…"

    private var browser: NWBrowser?

    func start() {
        stop()
        status = "Looking for Apple TV…"
        let browser = NWBrowser(
            for: .bonjour(type: DromeTVPairing.serviceType, domain: nil),
            using: DromeTVPairing.tcpParameters())
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state {
                    self?.status = error.localizedDescription
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.televisions = results.compactMap { result in
                    let name: String
                    if case .service(let serviceName, _, _, _) = result.endpoint {
                        name = serviceName
                    } else {
                        name = "Apple TV"
                    }
                    return FoundTV(
                        id: String(describing: result.endpoint),
                        name: name,
                        endpoint: result.endpoint)
                }
                if self?.televisions.isEmpty == true {
                    self?.status = "Looking for Apple TV…"
                } else {
                    self?.status = "Found \(self?.televisions.count ?? 0)"
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    func send(to tv: FoundTV, pin: String, account: Account, password: String) async throws {
        let connection = NWConnection(to: tv.endpoint, using: DromeTVPairing.tcpParameters())
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                    connection.stateUpdateHandler = nil
                case .failed(let error):
                    cont.resume(throwing: error)
                    connection.stateUpdateHandler = nil
                case .cancelled:
                    cont.resume(throwing: DromeTVPairingIO.PairingError.failed("Cancelled"))
                    connection.stateUpdateHandler = nil
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
        defer { connection.cancel() }
        let creds = DromeTVPairing.Credentials(
            pin: pin,
            serverURL: account.serverURL.absoluteString,
            username: account.username,
            password: password,
            wishlistURL: account.wishlistURL?.absoluteString,
            allowSelfSigned: account.allowSelfSigned)
        try await DromeTVPairingIO.send(creds, on: connection)
        let reply = try await DromeTVPairingIO.receive(DromeTVPairing.Reply.self, on: connection)
        guard reply.ok else {
            throw DromeTVPairingIO.PairingError.failed(reply.error ?? "Apple TV couldn’t sign in.")
        }
    }
}
#endif
