import Foundation

/// Persists non-secret account metadata. Managed credentials stay inside each
/// provider's isolated app-owned configuration directory and are maintained by
/// the provider's own CLI.
@MainActor
final class ProviderAccountsStore {
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
            profiles = decoded.filter { $0.kind == .managed && $0.configurationDirectory != nil }
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
        [ProviderAccountProfile.system(.claude)] + profiles
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
        let uuid = UUID()
        let id = ProviderAccountID.managed(uuid)
        let directory = rootDirectory
            .appending(path: "claude", directoryHint: .isDirectory)
            .appending(path: uuid.uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let normalized = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderAccountProfile(
            id: id,
            provider: .claude,
            displayName: normalized?.isEmpty == false ? normalized! : defaultClaudeName(),
            kind: .managed,
            configurationDirectory: directory.path,
            isEnabled: true,
            createdAt: .now
        )
    }

    func commit(_ profile: ProviderAccountProfile) {
        guard profile.kind == .managed,
              profile.configurationDirectory != nil,
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
        for provider in ProviderQuota.Provider.displayOrder {
            if selections[provider] == .account(id) {
                selections[provider] = .all
            }
        }
        persistProfiles()
        persistSelections()
        return removed
    }

    private func defaultClaudeName() -> String {
        "Claude \(profiles.filter { $0.provider == .claude }.count + 2)"
    }

    private func pruneInvalidSelections() {
        let valid = Set(allProfiles.map(\.id))
        for (provider, selection) in selections {
            if case .account(let id) = selection, !valid.contains(id) {
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
}
