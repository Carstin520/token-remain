import Foundation

/// Persists non-secret account metadata. Managed credentials stay either in an
/// isolated provider-owned CLI home or in a device-only Keychain item.
@MainActor
final class ProviderAccountsStore {
    enum StoreError: LocalizedError {
        case unsupportedProvider

        var errorDescription: String? {
            "This provider does not expose a safe multi-account sign-in method."
        }
    }
    static let profilesKey = "tokenRemain.providerAccounts.v1"
    static let selectionsKey = "tokenRemain.providerAccountSelections.v1"

    private let defaults: UserDefaults
    private let rootDirectory: URL
    private(set) var profiles: [ProviderAccountProfile]
    private(set) var selections: [ProviderQuota.Provider: ProviderAccountSelection]

    init(
        defaults: UserDefaults = .standard,
        rootDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()

        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([ProviderAccountProfile].self, from: data) {
            profiles = decoded.filter(Self.isValidManagedProfile)
        } else {
            profiles = []
        }

        if let data = defaults.data(forKey: Self.selectionsKey),
           let decoded = try? JSONDecoder().decode(
               [ProviderQuota.Provider: ProviderAccountSelection].self,
               from: data
           ) {
            selections = decoded
        } else {
            selections = [:]
        }
        pruneInvalidSelections()
    }

    var allProfiles: [ProviderAccountProfile] {
        let systemProfiles = ProviderQuota.Provider.displayOrder.compactMap { provider in
            provider.multiAccountCapability == nil ? nil : ProviderAccountProfile.system(provider)
        }
        return systemProfiles + profiles
    }

    func selection(for provider: ProviderQuota.Provider) -> ProviderAccountSelection {
        selections[provider] ?? .all
    }

    func setSelection(_ selection: ProviderAccountSelection, for provider: ProviderQuota.Provider) {
        switch selection {
        case .all:
            selections[provider] = .all
        case .account(let id):
            guard allProfiles.contains(where: { $0.provider == provider && $0.id == id }) else {
                return
            }
            selections[provider] = selection
        }
        persistSelections()
    }

    /// Creates an isolated Claude home but does not publish it to the account
    /// list until official CLI login succeeds.
    func prepareClaudeProfile(displayName: String?) throws -> ProviderAccountProfile {
        try prepareProfile(provider: .claude, displayName: displayName)
    }

    /// Creates unpublished account metadata. Isolated CLI homes are created
    /// with owner-only permissions; secret profiles receive no filesystem home.
    func prepareProfile(
        provider: ProviderQuota.Provider,
        displayName: String?
    ) throws -> ProviderAccountProfile {
        guard let capability = provider.multiAccountCapability else {
            throw StoreError.unsupportedProvider
        }
        let uuid = UUID()
        let id = ProviderAccountID.managed(uuid)
        let directory: URL?
        if capability.credentialKind == .isolatedCLI {
            let candidate = rootDirectory
                .appending(path: provider.directorySlug, directoryHint: .isDirectory)
                .appending(path: uuid.uuidString.lowercased(), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: candidate,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            directory = candidate
        } else {
            directory = nil
        }
        let normalized = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderAccountProfile(
            id: id,
            provider: provider,
            displayName: normalized?.isEmpty == false ? normalized! : defaultName(for: provider),
            kind: .managed,
            configurationDirectory: directory?.path,
            isEnabled: true,
            createdAt: .now
        )
    }

    func commit(_ profile: ProviderAccountProfile) {
        guard profile.kind == .managed,
              Self.isValidManagedProfile(profile),
              !profiles.contains(where: { $0.id == profile.id }) else { return }
        profiles.append(profile)
        persistProfiles()
    }

    func discardPreparedProfile(_ profile: ProviderAccountProfile) {
        guard !profiles.contains(where: { $0.id == profile.id }),
              let path = profile.configurationDirectory else { return }
        removeManagedDirectoryIfSafe(URL(fileURLWithPath: path))
    }

    func rename(_ id: ProviderAccountID, to name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 64,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].displayName = normalized
        persistProfiles()
    }

    func setEnabled(_ enabled: Bool, for id: ProviderAccountID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isEnabled = enabled
        persistProfiles()
    }

    @discardableResult
    func remove(_ id: ProviderAccountID) -> ProviderAccountProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = profiles.remove(at: index)
        if let path = removed.configurationDirectory {
            removeManagedDirectoryIfSafe(URL(fileURLWithPath: path))
        }
        try? ProviderAccountSecretStore(
            provider: removed.provider,
            accountID: removed.id
        ).delete()
        for provider in ProviderQuota.Provider.displayOrder {
            if selections[provider] == .account(id) {
                selections[provider] = .all
            }
        }
        persistProfiles()
        persistSelections()
        return removed
    }

    private func defaultName(for provider: ProviderQuota.Provider) -> String {
        "\(provider.displayName) \(profiles.filter { $0.provider == provider }.count + 2)"
    }

    private func pruneInvalidSelections() {
        for (provider, selection) in selections {
            if case .account(let id) = selection,
               !allProfiles.contains(where: { $0.provider == provider && $0.id == id }) {
                selections[provider] = .all
            }
        }
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
    }

    private func persistSelections() {
        if let data = try? JSONEncoder().encode(selections) {
            defaults.set(data, forKey: Self.selectionsKey)
        }
    }

    private func removeManagedDirectoryIfSafe(_ directory: URL) {
        let resolvedRoot = rootDirectory.standardizedFileURL
        let resolvedDirectory = directory.standardizedFileURL
        guard resolvedDirectory != resolvedRoot,
              resolvedDirectory.path.hasPrefix(resolvedRoot.path + "/") else { return }
        try? FileManager.default.removeItem(at: resolvedDirectory)
    }

    private static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "com.jamesli.usagedock", directoryHint: .isDirectory)
            .appending(path: "provider-accounts", directoryHint: .isDirectory)
    }

    private static func isValidManagedProfile(_ profile: ProviderAccountProfile) -> Bool {
        guard profile.kind == .managed,
              let kind = profile.provider.multiAccountCapability?.credentialKind else {
            return false
        }
        switch kind {
        case .isolatedCLI:
            return profile.configurationDirectory != nil
        case .keychainSecret:
            return profile.configurationDirectory == nil
        }
    }
}

private extension ProviderQuota.Provider {
    var directorySlug: String {
        rawValue.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
