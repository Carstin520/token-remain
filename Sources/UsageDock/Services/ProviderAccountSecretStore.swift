import Foundation

/// Per-profile secret storage. Profile metadata is safe to persist and sync;
/// credentials remain device-local and are never readable through UserDefaults.
struct ProviderAccountSecretStore: Sendable {
    let provider: ProviderQuota.Provider
    let accountID: ProviderAccountID

    private var keychain: KeychainSecretStore {
        KeychainSecretStore(
            service: "com.jamesli.usagedock.provider-account.\(provider.storageSlug)",
            account: accountID.rawValue,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    func load() -> String? {
        guard let value = try? keychain.read() else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try keychain.save(trimmed)
    }

    func delete() throws {
        try keychain.delete()
    }
}

private extension ProviderQuota.Provider {
    var storageSlug: String {
        rawValue.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
