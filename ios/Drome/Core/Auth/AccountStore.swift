import Foundation

/// Persists saved accounts (metadata in UserDefaults, passwords in Keychain)
/// and tracks which one is active.
@MainActor
final class AccountStore: ObservableObject {
    private static let accountsKey = "drome.accounts"
    private static let activeKey = "drome.activeAccount"

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeAccountID: UUID?

    var activeAccount: Account? {
        accounts.first { $0.id == activeAccountID }
    }

    init() {
        load()
        for account in accounts {
            if let password = password(for: account) {
                Keychain.set(password, for: passwordKey(account))
            }
        }
        MessagesShareBridge.syncAccounts(accounts, activeID: activeAccountID)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey) {
            activeAccountID = UUID(uuidString: raw)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
        UserDefaults.standard.set(activeAccountID?.uuidString, forKey: Self.activeKey)
        MessagesShareBridge.syncAccounts(accounts, activeID: activeAccountID)
    }

    func add(_ account: Account, password: String) {
        Keychain.set(password, for: passwordKey(account))
        accounts.removeAll { $0.serverURL == account.serverURL && $0.username == account.username }
        accounts.append(account)
        persist()
    }

    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        persist()
    }

    func remove(_ account: Account) {
        Keychain.delete(passwordKey(account))
        accounts.removeAll { $0.id == account.id }
        if activeAccountID == account.id {
            activeAccountID = accounts.first?.id
        }
        persist()
    }

    func setActive(_ account: Account?) {
        activeAccountID = account?.id
        persist()
    }

    func password(for account: Account) -> String? {
        Keychain.get(passwordKey(account))
    }

    private func passwordKey(_ account: Account) -> String {
        "drome.password.\(account.id.uuidString)"
    }
}
