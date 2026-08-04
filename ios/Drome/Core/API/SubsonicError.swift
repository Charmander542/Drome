import Foundation

enum SubsonicError: LocalizedError {
    case api(code: Int, message: String)
    case http(status: Int)
    case invalidURL
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .api(let code, let message):
            switch code {
            case 40: return "Wrong username or password."
            case 30: return "The server version is too old for this client."
            default: return message
            }
        case .http(let status):
            return "Server returned HTTP \(status)."
        case .invalidURL:
            return "The server URL is not valid."
        case .notLoggedIn:
            return "Not logged in."
        }
    }
}
