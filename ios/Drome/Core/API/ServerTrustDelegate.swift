import Foundation

/// URLSession delegate that optionally accepts self-signed certificates for a
/// specific host (the user's own server), keeping every other host on normal
/// system trust evaluation.
final class ServerTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let trustedHost: String?

    init(trustedHost: String?) {
        self.trustedHost = trustedHost
    }

    private func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trustedHost,
              challenge.protectionSpace.host.caseInsensitiveCompare(trustedHost) == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust
        else { return nil }
        return URLCredential(trust: trust)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = credential(for: challenge) {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = credential(for: challenge) {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
