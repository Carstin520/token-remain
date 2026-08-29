import Foundation

enum StoredCredentialStatus: Equatable, Sendable {
    case missing
    case available
    case authorizationRequired
    case failed

    init(keychainState: KeychainSecretStore.ReadState) {
        switch keychainState {
        case .missing:
            self = .missing
        case .available(let value):
            self = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .missing
                : .available
        case .authorizationRequired:
            self = .authorizationRequired
        case .invalidData, .failure:
            self = .failed
        }
    }
}

enum StoredCredentialActionError: LocalizedError, Sendable {
    case missing(String)
    case authorizationStillRequired

    var errorDescription: String? {
        switch self {
        case .missing(let provider):
            return L10n.format("datasource.credential_missing", provider)
        case .authorizationStillRequired:
            return L10n.text("datasource.credential_authorization_still_required")
        }
    }
}
