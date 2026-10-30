import Foundation

/// Per-account subscription prices the user entered on the cost card. Keys
/// are the opaque local `ProviderAccountID`; nothing here identifies the
/// account to a provider, and the values never leave this Mac.
@MainActor
final class SubscriptionCostStore: ObservableObject {
    static let shared = SubscriptionCostStore()
    static let overridesKey = "tokenRemain.subscriptionPriceOverrides.v1"

    @Published private(set) var overrides: [ProviderAccountID: SubscriptionPriceOverride]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.overridesKey)
            .flatMap { try? JSONDecoder().decode([String: SubscriptionPriceOverride].self, from: $0) }
            ?? [:]
        overrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            value.isValid ? (ProviderAccountID(rawValue: key), value) : nil
        })
    }

    /// Nil removes the override, returning the account to its list price —
    /// or off the card, when only the override had put it there. An invalid
    /// amount is rejected rather than stored.
    func setOverride(_ value: SubscriptionPriceOverride?, for id: ProviderAccountID) {
        if let value {
            guard value.isValid else { return }
            overrides[id] = value
        } else {
            overrides[id] = nil
        }
        persist()
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.overridesKey)
        }
    }
}
