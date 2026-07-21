import Foundation
import OSLog

/// Devin(Windsurf 系)日/周配额直查。参考 OpenUsage(MIT)的 Devin
/// provider,只读本机凭证(`~/.local/share/devin/credentials.toml` 的
/// `windsurf_api_key`,或 Devin 应用 state.vscdb 的登录态),调用
/// SeatManagement 的 GetUserStatus。API Key 长期有效,无刷新问题。
struct DevinUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case notLoggedIn
        case keyRejected(Int)
        case requestFailed(Int)
        case invalidResponse
        case quotaUnavailable

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return "未检测到 Devin 登录；安装并登录 Devin 后自动接入"
            case .keyRejected(let status):
                return "Devin 拒绝了当前凭证（HTTP \(status)）；重新登录 Devin 后恢复"
            case .requestFailed(let status):
                return "Devin 用量接口请求失败（HTTP \(status)）"
            case .invalidResponse:
                return "Devin 用量接口返回了无法识别的内容"
            case .quotaUnavailable:
                return "当前 Devin 账户未提供配额数据"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "DevinUsage")

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let auth = await DevinAuthReader().load() else {
            throw ServiceError.notLoggedIn
        }

        let url = URL(string: "\(auth.apiServerURL)/exa.seat_management_pb.SeatManagementService/GetUserStatus")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "apiKey": auth.apiKey,
                "ideName": "devin",
                "ideVersion": "1.108.2",
                "extensionName": "devin",
                "extensionVersion": "1.108.2",
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
            throw ServiceError.keyRejected(http.statusCode)
        default:
            throw ServiceError.requestFailed(http.statusCode)
        }
        let quota = try DevinUsageParser.parse(data, now: now)
        Self.logger.info("Devin quota served by SeatManagement API")
        return quota
    }
}

/// GetUserStatus 响应 → ProviderQuota。`userStatus.planStatus` 报的是
/// **剩余**百分比(dailyQuotaRemainingPercent / weeklyQuotaRemainingPercent),
/// 翻转为已用;重置为 unix 秒;计划名取 `planInfo.planName`。
enum DevinUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let userStatus = body["userStatus"] as? [String: Any] else {
            throw DevinUsageService.ServiceError.invalidResponse
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
            throw DevinUsageService.ServiceError.quotaUnavailable
        }
        return ProviderQuota(
            provider: .devin,
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

/// 只读发现 Devin 凭证:`~/.local/share/devin/credentials.toml` 的
/// `windsurf_api_key`(附可选 `api_server_url`),回退到 Devin 应用
/// `state.vscdb` 里 `windsurfAuthStatus` JSON 的 `apiKey`。
struct DevinAuthReader {
    struct Auth: Sendable {
        let apiKey: String
        let apiServerURL: String
    }

    static let defaultAPIServerURL = "https://server.codeium.com"

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    func load() async -> Auth? {
        if let text = try? String(
            contentsOf: homeDirectory.appending(path: ".local/share/devin/credentials.toml"),
            encoding: .utf8
        ), let key = Self.tomlString(text, key: "windsurf_api_key") {
            let server = Self.tomlString(text, key: "api_server_url")
                .flatMap(Self.cleanServerURL) ?? Self.defaultAPIServerURL
            return Auth(apiKey: key, apiServerURL: server)
        }

        let dbPath = homeDirectory
            .appending(path: "Library/Application Support/Devin/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: dbPath),
              let data = try? await ProcessRunner.run("/usr/bin/sqlite3", arguments: [
                  "-readonly", dbPath,
                  "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1;"
              ]),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = (object["apiKey"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return Auth(apiKey: key, apiServerURL: Self.defaultAPIServerURL)
    }

    /// 极简 TOML 取值:`key = "value"` 单行形式,足够覆盖 credentials.toml。
    static func tomlString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { continue }
            let afterKey = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard afterKey.hasPrefix("=") else { continue }
            let value = afterKey.dropFirst()
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func cleanServerURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("https://") else { return nil }
        var cleaned = trimmed
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        return cleaned.isEmpty ? nil : cleaned
    }
}

extension String {
    var nilIfEmptyString: String? { isEmpty ? nil : self }
}
