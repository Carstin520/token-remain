import Foundation
import OSLog

/// Reads Windsurf's own local login state and queries its read-only
/// SeatManagement status endpoint. Credentials are never copied, refreshed,
/// or written back by TokenRemain.
struct WindsurfUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case notLoggedIn
        case credentialsRejected(Int)
        case requestFailed(Int)
        case invalidResponse
        case quotaUnavailable

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return L10n.format("service.common.not_logged_in_install", "Windsurf")
            case .credentialsRejected(let status):
                return L10n.format("service.common.token_rejected_plain", "Windsurf", status)
            case .requestFailed(let status):
                return L10n.format("service.common.request_failed", "Windsurf", status)
            case .invalidResponse, .quotaUnavailable:
                return L10n.format("service.common.invalid_response", "Windsurf")
            }
        }
    }

    private static let logger = Logger(
        subsystem: "com.jamesli.usagedock",
        category: "WindsurfUsage"
    )

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(apiKey: nil, apiServerURL: nil, now: now)
    }

    func fetch(
        apiKey routedKey: String?,
        apiServerURL: String? = nil,
        now: Date = .now
    ) async throws -> ProviderQuota {
        let cleaned = routedKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth: WindsurfAuthReader.Auth?
        if let cleaned, !cleaned.isEmpty {
            auth = WindsurfAuthReader.Auth(
                apiKey: cleaned,
                apiServerURL: apiServerURL.flatMap(DevinAuthReader.cleanServerURL)
                    ?? WindsurfAuthReader.defaultAPIServerURL
            )
        } else {
            auth = await WindsurfAuthReader().load()
        }
        guard let auth else {
            throw ServiceError.notLoggedIn
        }
        guard let url = URL(
            string: "\(auth.apiServerURL)/exa.seat_management_pb.SeatManagementService/GetUserStatus"
        ) else {
            throw ServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "apiKey": auth.apiKey,
                "ideName": "windsurf",
                "ideVersion": "1.0",
                "extensionName": "windsurf",
                "extensionVersion": "1.0",
                "locale": "en"
            ]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ServiceError.credentialsRejected(http.statusCode)
        default:
            throw ServiceError.requestFailed(http.statusCode)
        }
        let quota = try WindsurfUsageParser.parse(data, now: now)
        Self.logger.info("Windsurf quota served by SeatManagement API")
        return quota
    }
}

enum WindsurfUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let userStatus = body["userStatus"] as? [String: Any] else {
            throw WindsurfUsageService.ServiceError.invalidResponse
        }
        let planStatus = userStatus["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let hideDaily = planInfo["hideDailyQuota"] as? Bool == true

        var windows: [QuotaWindow] = []
        if !hideDaily, let remaining = number(planStatus["dailyQuotaRemainingPercent"]) {
            windows.append(QuotaWindow(
                usedPercent: min(100, max(0, 100 - remaining)),
                windowMinutes: 1_440,
                resetsAt: unixDate(planStatus["dailyQuotaResetAtUnix"])
            ))
        }
        if let remaining = number(planStatus["weeklyQuotaRemainingPercent"]) {
            windows.append(QuotaWindow(
                usedPercent: min(100, max(0, 100 - remaining)),
                windowMinutes: 10_080,
                resetsAt: unixDate(planStatus["weeklyQuotaResetAtUnix"])
            ))
        }
        guard let primary = windows.first else {
            throw WindsurfUsageService.ServiceError.quotaUnavailable
        }
        return ProviderQuota(
            provider: .windsurf,
            primary: primary,
            secondary: windows.count > 1 ? windows[1] : nil,
            planName: (planInfo["planName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmptyString,
            capturedAt: now
        )
    }

    private static func unixDate(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

struct WindsurfAuthReader {
    struct Auth: Equatable, Sendable {
        let apiKey: String
        let apiServerURL: String
    }

    static let defaultAPIServerURL = "https://server.codeium.com"

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func load() async -> Auth? {
        if let key = environment["WINDSURF_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            let server = environment["WINDSURF_API_SERVER_URL"]
                .flatMap(DevinAuthReader.cleanServerURL) ?? Self.defaultAPIServerURL
            return Auth(apiKey: key, apiServerURL: server)
        }

        let dbPath = homeDirectory
            .appending(path: "Library/Application Support/Windsurf/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: dbPath),
              let data = try? await ProcessRunner.run("/usr/bin/sqlite3", arguments: [
                  "-readonly", dbPath,
                  "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1;"
              ]) else {
            return nil
        }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> Auth? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = (object["apiKey"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        let server = (object["apiServerUrl"] as? String)
            .flatMap(DevinAuthReader.cleanServerURL) ?? defaultAPIServerURL
        return Auth(apiKey: key, apiServerURL: server)
    }
}
