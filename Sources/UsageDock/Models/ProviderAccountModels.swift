import Foundation

/// Stable local identity for one provider account. The raw value is an opaque
/// app-owned identifier; provider credentials, email addresses and server-side
/// account IDs never become dictionary keys or cache filenames.
struct ProviderAccountID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    var id: String { rawValue }

    static func system(_ provider: ProviderQuota.Provider) -> ProviderAccountID {
        ProviderAccountID(rawValue: "system.\(provider.rawValue.lowercased())")
    }

    static func managed(_ uuid: UUID) -> ProviderAccountID {
        ProviderAccountID(rawValue: "managed.\(uuid.uuidString.lowercased())")
    }
}

struct ProviderAccountProfile: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case system
        case managed
    }

    let id: ProviderAccountID
    let provider: ProviderQuota.Provider
    var displayName: String
    let kind: Kind
    /// App-owned isolated provider home. Nil is reserved for the system account.
    let configurationDirectory: String?
    var isEnabled: Bool
    let createdAt: Date

    var isSystem: Bool { kind == .system }

    var credentialKind: ProviderAccountCredentialKind? {
        isSystem ? nil : provider.multiAccountCapability?.credentialKind
    }

    static func system(_ provider: ProviderQuota.Provider) -> ProviderAccountProfile {
        ProviderAccountProfile(
            id: .system(provider),
            provider: provider,
            displayName: "",
            kind: .system,
            configurationDirectory: nil,
            isEnabled: true,
            createdAt: .distantPast
        )
    }
}

enum ProviderAccountCredentialKind: String, Codable, Hashable, Sendable {
    /// The provider's official CLI owns authentication inside an isolated home.
    case isolatedCLI
    /// TokenRemain owns one opaque credential in the macOS Keychain.
    case keychainSecret
}

struct ProviderMultiAccountCapability: Hashable, Sendable {
    let credentialKind: ProviderAccountCredentialKind
    let allowsLocalActivation: Bool
}

extension ProviderQuota.Provider {
    /// Multi-account is deliberately opt-in. Providers whose only supported
    /// reader is the currently running desktop app remain single-account until
    /// they expose a safe profile or credential boundary.
    var multiAccountCapability: ProviderMultiAccountCapability? {
        switch self {
        case .claude:
            ProviderMultiAccountCapability(
                credentialKind: .isolatedCLI,
                allowsLocalActivation: false
            )
        case .codex:
            ProviderMultiAccountCapability(
                credentialKind: .isolatedCLI,
                // Selection changes TokenRemain's displayed account only. We
                // do not overwrite the user's live ~/.codex/auth.json.
                allowsLocalActivation: false
            )
        case .cursor, .grok, .zai, .zaiTeam, .copilot, .devin, .windsurf,
             .openrouter, .deepseek, .kimi, .minimax, .mimo, .qoder,
             .volcengine, .ollama, .thirdParty, .antigravity:
            ProviderMultiAccountCapability(
                credentialKind: .keychainSecret,
                allowsLocalActivation: false
            )
        case .opencode, .kiro:
            nil
        }
    }
}

enum ProviderAccountSelection: Codable, Hashable, Sendable {
    case all
    case account(ProviderAccountID)
}

struct ProviderAccountState: Sendable {
    var quota: ProviderQuota?
    var notice: String?
    var isRefreshing: Bool = false
}

struct ProviderAccountSnapshot: Identifiable, Sendable {
    let profile: ProviderAccountProfile
    let state: ProviderAccountState

    var id: ProviderAccountID { profile.id }
    var quota: ProviderQuota? { state.quota }
    var notice: String? { state.notice }
    var isRefreshing: Bool { state.isRefreshing }
}

/// Pure account-group derivations for the UI. Percentage windows are never
/// added: providers do not expose the absolute token capacity needed for a
/// meaningful total. Native-currency balances are summed only within a currency.
struct ProviderAccountSummary: Sendable {
    let accountCount: Int
    let availableCount: Int
    let lowAccountCount: Int
    let lowestRemainingPercent: Double?
    let balancesByCurrency: [String: Double]

    init(snapshots: [ProviderAccountSnapshot], lowThreshold: Double = 20) {
        let enabled = snapshots.filter(\.profile.isEnabled)
        let quotas = enabled.compactMap(\.quota)
        let remaining = quotas.map {
            $0.generalQuotaSummary(strategy: .lowestRemaining).remainingPercent
        }
        var balances: [String: Double] = [:]
        for balance in quotas.compactMap(\.accountBalance) where balance.amount.isFinite {
            let currency = balance.currencyCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !currency.isEmpty else { continue }
            balances[currency, default: 0] += max(0, balance.amount)
        }

        accountCount = enabled.count
        availableCount = quotas.count
        lowAccountCount = remaining.count(where: { $0 <= lowThreshold })
        lowestRemainingPercent = remaining.min()
        balancesByCurrency = balances
    }
}
