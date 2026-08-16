import Foundation

/// HTTP client for Drome Connect on the companion server.
struct DromeConnectClient {
    enum ConnectError: LocalizedError {
        case notConfigured
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No companion server configured. Set its URL in Settings."
            case .server(let message):
                return message
            }
        }
    }

    private struct ServerError: Decodable { var error: String? }

    let baseURL: URL
    let session: URLSession
    let authItems: () -> [URLQueryItem]

    private func url(_ path: String, extraQuery: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ConnectError.notConfigured
        }
        var base = components.path
        if base.hasSuffix("/") { base.removeLast() }
        components.path = base + path
        var items = authItems().filter { ["u", "t", "s"].contains($0.name) }
        items.append(contentsOf: extraQuery)
        components.queryItems = items
        guard let url = components.url else { throw ConnectError.notConfigured }
        return url
    }

    private func sendRaw(path: String, method: String,
                         extraQuery: [URLQueryItem] = [],
                         body: (some Encodable)? = Optional<Int>.none) async throws -> Data {
        var request = URLRequest(url: try url(path, extraQuery: extraQuery))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw ConnectError.server(message ?? "Connect error (HTTP \(status)).")
        }
        return data
    }

    private func send<T: Decodable>(_ type: T.Type, path: String, method: String,
                                    extraQuery: [URLQueryItem] = [],
                                    body: (some Encodable)? = Optional<Int>.none) async throws -> T {
        let data = try await sendRaw(path: path, method: method, extraQuery: extraQuery, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func putDevice(_ device: ConnectDeviceHeartbeat) async throws -> ConnectDevice {
        try await send(ConnectDevice.self, path: "/connect/devices/\(device.id)", method: "PUT", body: device)
    }

    func listDevices() async throws -> [ConnectDevice] {
        struct R: Decodable { var devices: [ConnectDevice] }
        return try await send(R.self, path: "/connect/devices", method: "GET").devices
    }

    func deleteDevice(id: String) async throws {
        struct R: Decodable { var ok: Bool? }
        _ = try await send(R.self, path: "/connect/devices/\(id)", method: "DELETE")
    }

    func putSession(_ body: ConnectSessionPut) async throws -> ConnectSession {
        try await send(ConnectSession.self, path: "/connect/session", method: "PUT", body: body)
    }

    func getSession() async throws -> ConnectSession? {
        struct R: Decodable { var session: ConnectSession? }
        return try await send(R.self, path: "/connect/session", method: "GET").session
    }

    func postCommand(_ body: ConnectCommandPost) async throws -> ConnectCommand {
        try await send(ConnectCommand.self, path: "/connect/commands", method: "POST", body: body)
    }

    func listCommands(deviceId: String, after: Double) async throws -> [ConnectCommand] {
        struct R: Decodable { var commands: [ConnectCommand] }
        return try await send(
            R.self,
            path: "/connect/commands",
            method: "GET",
            extraQuery: [
                URLQueryItem(name: "deviceId", value: deviceId),
                URLQueryItem(name: "after", value: String(after)),
            ]
        ).commands
    }

    func ackCommands(ids: [String]) async throws {
        struct Body: Encodable { var ids: [String] }
        struct R: Decodable { var ok: Bool? }
        _ = try await send(R.self, path: "/connect/commands/ack", method: "POST", body: Body(ids: ids))
    }
}

struct ConnectDeviceHeartbeat: Encodable {
    var id: String
    var name: String
    var platform: String
    var model: String?
    var isPlaying: Bool
    var songId: String?
    var songTitle: String?
    var songArtist: String?
    var elapsed: Double
    var duration: Double
    var capabilities: [String]
}

struct ConnectSessionPut: Encodable {
    var activeDeviceId: String
    var isPlaying: Bool
    var snapshot: PlaybackSessionSnapshot?
}

struct ConnectCommandPost: Encodable {
    var type: String
    var fromDeviceId: String
    var targetDeviceId: String
    var seekTo: Double?
}
