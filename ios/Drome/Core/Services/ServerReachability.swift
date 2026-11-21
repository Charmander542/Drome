import Foundation

/// Probes home vs away URLs and picks the reachable base (Nautiline-style).
@MainActor
enum ServerReachability {
    static func probeAndSelect(client: SubsonicClient, account: Account) async {
        guard let home = account.homeURL else {
            client.setBaseURL(account.serverURL)
            return
        }
        // Prefer home when it answers quickly.
        client.setBaseURL(home)
        do {
            try await client.ping(timeout: 2.5)
            DromeDiagnostics.logNetwork("reachability home OK \(home.host ?? "")")
            return
        } catch {
            DromeDiagnostics.logNetwork("reachability home failed → away")
        }
        client.setBaseURL(account.serverURL)
        do {
            try await client.ping(timeout: 8)
            DromeDiagnostics.logNetwork("reachability away OK \(account.serverURL.host ?? "")")
        } catch {
            DromeDiagnostics.logNetwork("reachability away also failed")
        }
    }
}
