import Foundation

/// Keeps app-owned Keychain items isolated between the production app and
/// locally signed development variants. Production keeps the historical
/// service names so existing installations continue to find their secrets.
struct AppOwnedKeychainNamespace: Equatable, Sendable {
    static let productionBundleIdentifier = "com.jamesli.usagedock"

    let servicePrefix: String

    static var current: Self {
        Self(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    init(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              bundleIdentifier.hasPrefix(Self.productionBundleIdentifier + ".") else {
            servicePrefix = Self.productionBundleIdentifier
            return
        }
        servicePrefix = bundleIdentifier
    }

    func service(_ suffix: String) -> String {
        "\(servicePrefix).\(suffix)"
    }
}
