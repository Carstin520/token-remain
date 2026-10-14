import Foundation

/// Opt-in, app-owned web session. Never imports browser storage or refreshes a
/// third-party credential. An explicit web session replaces only the system
/// Claude quota source, never an isolated CLI account.
struct ClaudeWebUsageService: Sendable {
    struct Configuration: Codable, Sendable {
        let sessionKey: String
        var organizationID: String? = nil

        static func decode(_ value: String) throws -> Self {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let config: Self
            if trimmed.hasPrefix("{") {
                guard let data = trimmed.data(using: .utf8), let parsed = try? JSONDecoder().decode(Self.self, from: data) else {
                    throw ServiceError.invalidCookie
                }
                config = parsed
            } else {
                config = Self(sessionKey: sessionKeyValue(in: trimmed).map(String.init) ?? trimmed)
            }
            guard !config.sessionKey.isEmpty, config.sessionKey.utf8.count <= 8192,
                  config.sessionKey.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != ";" }),
                  config.organizationID == nil || UUID(uuidString: config.organizationID!) != nil else {
                throw ServiceError.invalidCookie
            }
            return config
        }

        func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }

        /// The `sessionKey` value inside whatever the user copied: a raw Cookie
        /// string, a `Cookie:` request header or a "Copy as cURL" command. The
        /// name must start a cookie pair so `xsessionKey=` never matches.
        static func sessionKeyValue(in text: String) -> Substring? {
            var searchStart = text.startIndex
            while let range = text.range(of: "sessionKey=", range: searchStart..<text.endIndex) {
                let startsPair = range.lowerBound == text.startIndex
                    || text[text.index(before: range.lowerBound)].isWhitespace
                    || ";:'\"".contains(text[text.index(before: range.lowerBound)])
                if startsPair {
                    let value = text[range.upperBound...].prefix { !$0.isWhitespace && !";'\"".contains($0) }
                    if !value.isEmpty { return value }
                }
                searchStart = range.upperBound
            }
            return nil
        }

        /// Clipboard import accepts only text that is recognisably a claude.ai
        /// session, so an unrelated copied secret never lands in the field.
        static func recognizedCredential(in text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = sessionKeyValue(in: trimmed).map(String.init)
                ?? (trimmed.hasPrefix("sk-ant-sid") ? trimmed : nil)
            guard let candidate, (try? decode(candidate)) != nil else { return nil }
            return candidate
        }
    }

    /// An organization the session can read, offered when the account belongs
    /// to more than one so the user picks by name instead of copying a UUID.
    struct OrganizationChoice: Equatable, Hashable, Sendable, Identifiable {
        let id: String
        let name: String?

        /// Names are not unique (two "Personal" workspaces are common), so a
        /// repeated name carries a short id suffix to stay distinguishable.
        static func labels(for choices: [Self]) -> [String: String] {
            let names = choices.map { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            var labels: [String: String] = [:]
            for (choice, name) in zip(choices, names) {
                if name.isEmpty {
                    labels[choice.id] = choice.id
                } else if names.filter({ $0 == name }).count > 1 {
                    labels[choice.id] = "\(name) (\(choice.id.prefix(8)))"
                } else {
                    labels[choice.id] = name
                }
            }
            return labels
        }
    }

    enum ServiceError: LocalizedError {
        case invalidCookie, expired, forbidden, invalidResponse, requestFailed(Int)
        case organizationRequired([OrganizationChoice])
        case rateLimited(retryAfterSeconds: Int?)
        var errorDescription: String? {
            switch self {
            case .invalidCookie: L10n.text("claude.web.invalid_cookie")
            case .expired: L10n.text("claude.web.expired")
            case .forbidden: L10n.text("claude.web.forbidden")
            case .organizationRequired: L10n.text("claude.web.organization_required")
            case .invalidResponse: L10n.text("claude.web.invalid_response")
            case .requestFailed(let status): L10n.format("service.common.request_failed_plain", "Claude Web", status)
            case .rateLimited(let seconds): ClaudeUsageService.ServiceError.rateLimited(retryAfterSeconds: seconds).errorDescription
            }
        }

        /// Same budget as the OAuth source: the system Claude card polls claude.ai
        /// through whichever source is configured.
        var retryDelay: TimeInterval {
            if case .rateLimited(let seconds?) = self { return max(60, TimeInterval(seconds)) }
            return 300
        }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    // No cookie persistence, cache, redirect credential forwarding, or browser store.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    func fetch(configuration value: String, now: Date = .now, timeout: TimeInterval = 30,
               perform: @escaping Transport = { try await session.data(for: $0) }) async throws -> ProviderQuota {
        let configuration = try Configuration.decode(value)
        return try await AsyncDeadline.run(timeout: timeout) {
            func read(_ path: String) async throws -> Data {
                try Task.checkCancellation()
                var request = URLRequest(url: URL(string: "https://claude.ai/api/\(path)")!)
                request.timeoutInterval = 15
                request.setValue("sessionKey=\(configuration.sessionKey)", forHTTPHeaderField: "Cookie")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await perform(request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
                switch http.statusCode {
                case 200: return data
                case 401: throw ServiceError.expired
                case 403: throw ServiceError.forbidden // challenge != proven expired session
                case 429: throw ServiceError.rateLimited(retryAfterSeconds: ClaudeOAuthUsageService.retryAfterSeconds(http, now: now))
                default: throw ServiceError.requestFailed(http.statusCode)
                }
            }
            let organizationsData = try await read("organizations")
            struct Organization: Decodable { let uuid: String; let name: String?; let capabilities: [String]? }
            guard let organizations = try? JSONDecoder().decode([Organization].self, from: organizationsData) else {
                throw ServiceError.invalidResponse
            }
            let eligible = organizations.filter { $0.capabilities?.contains("chat") == true }
            let organization: Organization
            if let id = configuration.organizationID,
               let selected = organizations.first(where: { $0.uuid == id }) { organization = selected }
            else if configuration.organizationID == nil, eligible.count == 1 { organization = eligible[0] }
            else if configuration.organizationID == nil, organizations.count == 1 { organization = organizations[0] }
            else {
                // Chat-capable organizations first: those are the ones with a
                // usage page, the others are API-only workspaces.
                let ordered = eligible + organizations.filter { $0.capabilities?.contains("chat") != true }
                throw ServiceError.organizationRequired(ordered.compactMap { organization in
                    UUID(uuidString: organization.uuid) == nil
                        ? nil
                        : OrganizationChoice(id: organization.uuid, name: organization.name)
                })
            }
            guard UUID(uuidString: organization.uuid) != nil else { throw ServiceError.invalidResponse }
            let data = try await read("organizations/\(organization.uuid)/usage")
            var quota = try ClaudeOAuthUsageParser.parse(data, now: now)
            // This source marker also prevents retaining scoped windows from an
            // earlier OAuth account when the user changes the system source.
            quota.attribution = QuotaAttribution(provider: .claude, displayName: "Claude Web", routeIdentifier: "claude-web:\(organization.uuid)")
            return quota
        }
    }
}
