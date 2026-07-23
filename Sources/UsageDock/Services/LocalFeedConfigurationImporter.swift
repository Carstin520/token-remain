import Foundation

struct LocalFeedConfigurationImporter: Sendable {
    struct LocalSecrets: Decodable, Sendable {
        let xBearerToken: String

        enum CodingKeys: String, CodingKey {
            case xBearerToken = "XBearerToken"
        }
    }

    enum ImportError: LocalizedError {
        case emptyToken
        case unreadableFile

        var errorDescription: String? {
            switch self {
            case .emptyToken:
                return L10n.text("feed.config.empty_token")
            case .unreadableFile:
                return L10n.text("feed.config.unreadable")
            }
        }
    }

    func token(from url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let secrets = try? PropertyListDecoder().decode(LocalSecrets.self, from: data) else {
            throw ImportError.unreadableFile
        }
        let token = secrets.xBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token != "PASTE_YOUR_X_API_BEARER_TOKEN_HERE" else {
            throw ImportError.emptyToken
        }
        return token
    }
}
