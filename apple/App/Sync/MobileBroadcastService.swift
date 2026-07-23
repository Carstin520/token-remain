import Foundation
import Security
import TokenRemainSyncKit

enum MobileBroadcastConfiguration {
    static var baseURL: URL? {
        guard let rawValue = Bundle.main.object(
            forInfoDictionaryKey: "TokenRemainBroadcastBaseURL"
        ) as? String,
              let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else {
            return nil
        }
        return url
    }

    static var feedEndpoint: URL? {
        baseURL?.appending(path: "v1/ai-feed")
    }

    static var deviceRegistrationEndpoint: URL? {
        baseURL?.appending(path: "v1/devices/register")
    }
}

enum MobileBroadcastPreferences {
    private static let notificationsKey = "broadcastNotificationsEnabled"

    static var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: notificationsKey) }
        set { UserDefaults.standard.set(newValue, forKey: notificationsKey) }
    }
}

actor MobileBroadcastService {
    static let shared = MobileBroadcastService()

    enum ServiceError: Error {
        case invalidResponse
        case api(Int)
        case invalidKeychainData
        case keychain(OSStatus)
    }

    private struct FeedPayload: Decodable {
        let items: [FeedItem]
    }

    private struct FeedItem: Decodable {
        struct Author: Decodable {
            let username: String
            let displayName: String
        }

        let id: String
        let text: String
        let author: Author
        let publishedAt: Date
        let url: URL
        let priority: String?
    }

    private struct RegistrationPayload: Encodable {
        let installationId: String
        let registrationKey: String
        let deviceToken: String
        let platform: String
        let locale: String
        let timezone: String
        let notificationsEnabled: Bool
    }

    private struct UnregistrationPayload: Encodable {
        let registrationKey: String
    }

    private let installationIDKey = "broadcastInstallationID"
    private let lastDeviceTokenKey = "broadcastLastDeviceToken"
    private let keychainService = "com.jamesli.tokenremain.broadcast"
    private let keychainAccount = "device-registration-key"

    func fetchFeed() async throws -> SyncedCuratedFeed? {
        guard let endpoint = MobileBroadcastConfiguration.feedEndpoint else { return nil }
        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.api(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(FeedPayload.self, from: data)
        let posts = payload.items.prefix(SyncedCuratedFeed.maximumPosts).map { item in
            SyncedCuratedPost(
                id: item.id,
                username: item.author.username,
                displayName: item.author.displayName,
                text: item.text,
                createdAt: item.publishedAt,
                url: item.url,
                priority: priority(item.priority)
            )
        }
        return SyncedCuratedFeed(posts: Array(posts), capturedAt: Date())
    }

    func register(deviceToken: Data, platform: String) async throws {
        guard let endpoint = MobileBroadcastConfiguration.deviceRegistrationEndpoint else {
            return
        }
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let payload = RegistrationPayload(
            installationId: installationID(),
            registrationKey: try registrationKey(),
            deviceToken: token,
            platform: platform,
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            notificationsEnabled: true
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(payload)
        try await perform(request)
        UserDefaults.standard.set(token, forKey: lastDeviceTokenKey)
    }

    func unregister() async throws {
        guard let endpoint = MobileBroadcastConfiguration.deviceRegistrationEndpoint,
              UserDefaults.standard.string(forKey: lastDeviceTokenKey) != nil
        else {
            return
        }
        let deviceEndpoint = endpoint
            .deletingLastPathComponent()
            .appending(path: installationID())
        var request = URLRequest(url: deviceEndpoint)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            UnregistrationPayload(registrationKey: try registrationKey())
        )
        try await perform(request)
        UserDefaults.standard.removeObject(forKey: lastDeviceTokenKey)
    }

    private func priority(_ rawValue: String?) -> SyncedCuratedPost.Priority {
        switch rawValue {
        case "token_reset": return .tokenReset
        case "major_update": return .majorUpdate
        default: return .normal
        }
    }

    private func perform(_ request: URLRequest) async throws {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.api(http.statusCode)
        }
    }

    private func installationID() -> String {
        if let value = UserDefaults.standard.string(forKey: installationIDKey), !value.isEmpty {
            return value
        }
        let value = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(value, forKey: installationIDKey)
        return value
    }

    private func registrationKey() throws -> String {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if readStatus == errSecSuccess {
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty
            else {
                throw ServiceError.invalidKeychainData
            }
            return value
        }
        guard readStatus == errSecItemNotFound else {
            throw ServiceError.keychain(readStatus)
        }

        let value = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
        var add = keychainQuery
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ServiceError.keychain(addStatus)
        }
        return value
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }
}
