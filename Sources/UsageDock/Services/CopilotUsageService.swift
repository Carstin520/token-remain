import Foundation
import OSLog

/// GitHub Copilot 月度额度直查。参考 OpenUsage(MIT)的 Copilot provider,
/// 只读本机已有的 GitHub OAuth token(Copilot 编辑器配置 → gh CLI 配置 →
/// gh 钥匙串),调用官方客户端同款的 copilot_internal/user 接口。
/// 绝不刷新、绝不写回。
struct CopilotUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case notLoggedIn
        case tokenRejected(Int)
        case requestFailed(Int)
        case invalidResponse
        case quotaUnavailable

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return L10n.text("service.copilot.not_logged_in")
            case .tokenRejected(let status):
                return L10n.format("service.copilot.token_rejected", status)
            case .requestFailed(let status):
                return L10n.format("service.common.request_failed", "Copilot", status)
            case .invalidResponse:
                return L10n.format("service.common.invalid_response", "Copilot")
            case .quotaUnavailable:
                return L10n.text("service.copilot.no_personal_quota")
            }
        }
    }

    private static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "CopilotUsage")

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let token = CopilotTokenReader().load() else {
            throw ServiceError.notLoggedIn
        }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 15
        // 接口按官方 Copilot 客户端的形态放行,注意是 `token` 方案不是 Bearer。
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ServiceError.tokenRejected(http.statusCode)
        default:
            throw ServiceError.requestFailed(http.statusCode)
        }
        let quota = try CopilotUsageParser.parse(data, now: now)
        Self.logger.info("Copilot quota served by copilot_internal API")
        return quota
    }
}

/// copilot_internal/user 响应 → ProviderQuota。2026 起所有套餐按 AI Credits
/// 计费:`quota_snapshots.premium_interactions` 是月度积分池(percent_remaining
/// 或 entitlement/remaining),`quota_reset_date` 为重置日;免费档退化为
/// chat/completions 计数。`-1` 哨兵值表示无限,零 entitlement 是组织席位的
/// 占位,都不能当真实额度渲染。
enum CopilotUsageParser {
    static let monthlyMinutes = 43_200

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CopilotUsageService.ServiceError.invalidResponse
        }
        let resetsAt = resetDate(body["quota_reset_date"]) ?? resetDate(body["limited_user_reset_date"])
        let snapshots = body["quota_snapshots"] as? [String: Any]

        var windows: [QuotaWindow] = []
        if let premium = usedPercent(snapshots?["premium_interactions"]) {
            windows.append(QuotaWindow(usedPercent: premium, windowMinutes: monthlyMinutes, resetsAt: resetsAt))
        } else {
            // 免费档:chat / completions 各自的月度计数池。
            for key in ["chat", "completions"] {
                if let percent = usedPercent(snapshots?[key]) {
                    windows.append(QuotaWindow(usedPercent: percent, windowMinutes: monthlyMinutes, resetsAt: resetsAt))
                }
            }
        }

        guard let primary = windows.first else {
            throw CopilotUsageService.ServiceError.quotaUnavailable
        }
        return ProviderQuota(
            provider: .copilot,
            primary: primary,
            secondary: windows.count > 1 ? windows[1] : nil,
            planName: planLabel(body["copilot_plan"]),
            capturedAt: now
        )
    }

    /// "copilot_pro" → "Copilot Pro"。
    static func planLabel(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func usedPercent(_ value: Any?) -> Double? {
        guard let snapshot = value as? [String: Any] else { return nil }
        let entitlement = number(snapshot["entitlement"])
        let remaining = number(snapshot["remaining"])
        // 无限哨兵与零 entitlement 占位都不构成真实额度。
        if snapshot["unlimited"] as? Bool == true || entitlement == -1 || remaining == -1 {
            return nil
        }
        if entitlement == 0 { return nil }
        if let percentRemaining = number(snapshot["percent_remaining"]) {
            return min(100, max(0, 100 - percentRemaining))
        }
        if let entitlement, entitlement > 0, let remaining {
            return min(100, max(0, 100 - remaining / entitlement * 100))
        }
        return nil
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// 只读发现本机 GitHub token。顺序:Copilot 编辑器配置
/// `~/.config/github-copilot/apps.json`(旧版 `hosts.json`)里 github.com 条目
/// 的 `oauth_token` → gh CLI `~/.config/gh/hosts.yml` github.com 块的
/// `oauth_token` → 钥匙串 `gh:github.com`(go-keyring 包装)。
/// 只认 github.com 的 token:企业实例的 token 发给 api.github.com 必然 401。
struct CopilotTokenReader {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var keychainPayload: @Sendable () -> String? = {
        KeychainRead.genericPassword(service: "gh:github.com", interaction: .disallowed).payload
    }

    func load() -> String? {
        for path in [".config/github-copilot/apps.json", ".config/github-copilot/hosts.json"] {
            if let text = try? String(contentsOf: homeDirectory.appending(path: path), encoding: .utf8),
               let token = Self.token(fromEditorJSON: text) {
                return token
            }
        }
        if let text = try? String(
            contentsOf: homeDirectory.appending(path: ".config/gh/hosts.yml"),
            encoding: .utf8
        ), let token = Self.yamlValue(text, key: "oauth_token") {
            return token
        }
        guard let raw = keychainPayload() else { return nil }
        return GoKeyring.unwrap(raw)
    }

    /// 配置是 `{host: {oauth_token}}`;host 为 "github.com" 或 "github.com:<appId>"。
    static func token(fromEditorJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        for (key, value) in object where key == "github.com" || key.hasPrefix("github.com:") {
            if let token = ((value as? [String: Any])?["oauth_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                return token
            }
        }
        return nil
    }

    /// 在 hosts.yml 的 github.com 块内读缩进的 `key: value`;严格限定块内,
    /// 避免同文件里 GitHub Enterprise 块的 token 混入。
    static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        let prefix = key + ":"
        let hostHeader = host + ":"
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces).hasPrefix(hostHeader)
                continue
            }
            guard inHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
