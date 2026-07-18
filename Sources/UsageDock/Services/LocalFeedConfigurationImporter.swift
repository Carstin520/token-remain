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
                return "工程配置文件中的 XBearerToken 为空"
            case .unreadableFile:
                return "无法读取工程中的 UsageDockFeed.local.plist"
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
