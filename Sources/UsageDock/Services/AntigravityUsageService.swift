import Foundation
import OSLog

/// Antigravity(Google 家的 agentic IDE)配额池直查。优先复用正在运行的
/// Antigravity language server；仅在本地服务不可用时，无交互地尝试已有
/// 钥匙串授权。**绝不用 Google OAuth 代刷**，也绝不在后台触发授权弹窗。
struct AntigravityUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case notLoggedIn
        case runningButQuotaUnavailable
        case staleLogin
        case requestFailed(Int)
        case invalidResponse
        case quotaUnavailable

        var errorDescription: String? {
            description(bundle: AppResourceBundle.bundle)
        }

        func description(bundle: Bundle) -> String? {
            switch self {
            case .notLoggedIn:
                return L10n.text("service.antigravity.not_logged_in", bundle: bundle)
            case .runningButQuotaUnavailable:
                return L10n.text("service.antigravity.running_no_quota", bundle: bundle)
            case .staleLogin:
                return L10n.format(
                    "service.common.stale_login_reopen",
                    "Antigravity",
                    bundle: bundle
                )
            case .requestFailed(let status):
                return L10n.format("service.antigravity.request_failed", status, bundle: bundle)
            case .invalidResponse:
                return L10n.text("service.antigravity.invalid_response", bundle: bundle)
            case .quotaUnavailable:
                return L10n.text("service.antigravity.no_quota_data", bundle: bundle)
            }
        }
    }

    enum ProbeFallbackDisposition: Equatable {
        case notDetected
        case runningButQuotaUnavailable

        var failure: ServiceError {
            switch self {
            case .notDetected:
                return .notLoggedIn
            case .runningButQuotaUnavailable:
                return .runningButQuotaUnavailable
            }
        }
    }

    private static let quotaSummaryURLs = [
        URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
        URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    ]
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "AntigravityUsage")

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        // Prefer Antigravity's loopback quota service. It uses the already-running
        // app session and never touches the cross-app `gemini` Keychain item.
        let fallbackDisposition: ProbeFallbackDisposition
        do {
            let localQuota = try await AntigravityLocalUsageProbe().fetch(now: now)
            Self.logger.info("Antigravity quota served by local language server")
            return localQuota
        } catch {
            fallbackDisposition = Self.fallbackDisposition(for: error)
        }

        // Retain the old remote path only as a non-interactive fallback. If the
        // user previously granted this signed app access it continues to work;
        // otherwise Keychain returns immediately instead of showing a prompt.
        guard let token = AntigravityTokenReader().load() else {
            throw fallbackDisposition.failure
        }
        do {
            return try await fetch(token: token, now: now)
        } catch {
            guard fallbackDisposition == .runningButQuotaUnavailable else {
                throw error
            }
            throw ServiceError.runningButQuotaUnavailable
        }
    }

    static func fallbackDisposition(for error: Error) -> ProbeFallbackDisposition {
        guard let probeError = error as? AntigravityLocalUsageProbe.ProbeError else {
            return .notDetected
        }
        switch probeError {
        case .processUnavailable:
            return .notDetected
        case .portUnavailable, .quotaUnavailable:
            return .runningButQuotaUnavailable
        }
    }

    /// Managed profiles use an explicitly supplied short-lived access token.
    /// They never probe the running app or inherit its single Keychain account.
    func fetch(accessToken: String, now: Date = .now) async throws -> ProviderQuota {
        let cleaned = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ServiceError.notLoggedIn }
        return try await fetch(
            token: AntigravityTokenReader.Token(
                accessToken: cleaned,
                expiry: JWT.expiry(cleaned)
            ),
            now: now
        )
    }

    private func fetch(token: AntigravityTokenReader.Token, now: Date) async throws -> ProviderQuota {
        if let expiry = token.expiry ?? JWT.expiry(token.accessToken), expiry <= now {
            throw ServiceError.staleLogin
        }

        var lastStatus = 0
        for url in Self.quotaSummaryURLs {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = Data("{}".utf8)
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("antigravity", forHTTPHeaderField: "User-Agent")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else {
                continue
            }
            switch http.statusCode {
            case 200..<300:
                let quota = try AntigravityUsageParser.parse(data, now: now)
                Self.logger.info("Antigravity quota served by Cloud Code quota summary")
                return quota
            case 401, 403:
                // 同一个 token 在另一个 base 也必然失败,不再尝试。
                throw ServiceError.staleLogin
            default:
                lastStatus = http.statusCode
                continue
            }
        }
        throw lastStatus > 0 ? ServiceError.requestFailed(lastStatus) : ServiceError.invalidResponse
    }
}

/// RetrieveUserQuotaSummary 响应 → ProviderQuota。响应为
/// `{"groups": [{"buckets": [{bucketId, remainingFraction, resetTime}]}]}`
/// (或包一层 `response`)。四个池按精确 bucketId 匹配:`gemini-5h` /
/// `gemini-weekly` 为主池(映射 primary/secondary),`3p-5h` / `3p-weekly`
/// 是共享的第三方(Claude)池,作为可由用户显示/隐藏的 scoped windows。
/// `remainingFraction` 0…1,翻转为已用百分比。
enum AntigravityUsageParser {
    /// 目前已知的四个配额桶。别的 bucketId 语义未知,渲染前先取证:
    /// 记一条 info 日志后跳过,不静默丢。
    private static let knownBucketIDs: Set<String> = [
        "gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"
    ]
    private static let logger = Logger(
        subsystem: "com.jamesli.usagedock",
        category: "AntigravityUsage"
    )

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AntigravityUsageService.ServiceError.invalidResponse
        }
        let container = (root["response"] as? [String: Any]) ?? root
        guard let groups = container["groups"] as? [[String: Any]] else {
            throw AntigravityUsageService.ServiceError.invalidResponse
        }

        var pools: [String: QuotaWindow] = [:]
        for group in groups {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = bucket["bucketId"] as? String,
                      pools[id] == nil,
                      let fraction = number(bucket["remainingFraction"]), fraction.isFinite else {
                    continue
                }
                guard knownBucketIDs.contains(id) else {
                    logger.info(
                        "Skipping unknown Antigravity quota bucket \(id, privacy: .public)"
                    )
                    continue
                }
                let minutes = id.hasSuffix("-weekly") ? 10_080 : 300
                pools[id] = QuotaWindow(
                    usedPercent: min(100, max(0, (1 - fraction) * 100)),
                    windowMinutes: minutes,
                    resetsAt: isoDate(bucket["resetTime"])
                )
            }
        }

        guard let primary = pools["gemini-5h"] ?? pools["gemini-weekly"] else {
            throw AntigravityUsageService.ServiceError.quotaUnavailable
        }
        let secondary = pools["gemini-5h"] == nil ? nil : pools["gemini-weekly"]
        // observedAt 必填:一次刷新只回 gemini 桶时,缺时间戳的 3P 行会被
        // `retainingActiveScopedWindows` 当作过期立即清掉,造成行闪断。
        let thirdPartyWindows: [ScopedQuotaWindow] = [
            pools["3p-5h"].map {
                ScopedQuotaWindow(
                    scopeID: "antigravity_3p_5h",
                    displayName: "Claude / Third-party",
                    window: $0,
                    observedAt: now
                )
            },
            pools["3p-weekly"].map {
                ScopedQuotaWindow(
                    scopeID: "antigravity_3p_weekly",
                    displayName: "Claude / Third-party",
                    window: $0,
                    observedAt: now
                )
            }
        ].compactMap { $0 }
        return ProviderQuota(
            provider: .antigravity,
            primary: primary,
            secondary: secondary,
            planName: nil,
            capturedAt: now,
            scopedWindows: thirdPartyWindows.isEmpty ? nil : thirdPartyWindows
        )
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// 只读发现 Antigravity 的 Google OAuth token:钥匙串 service `gemini`、
/// account `antigravity`,值可能是 go-keyring base64 包装的 JSON
/// `{token: {access_token, expiry}}`,或裸 token / `Bearer x`。
struct AntigravityTokenReader {
    struct Token: Sendable {
        let accessToken: String
        let expiry: Date?
    }

    var keychainPayload: @Sendable () -> String? = {
        KeychainRead.genericPassword(
            service: "gemini",
            account: "antigravity",
            interaction: .disallowed
        ).payload
    }

    func load() -> Token? {
        guard let raw = keychainPayload(),
              let text = GoKeyring.unwrap(raw) else {
            return nil
        }
        return Self.parse(text)
    }

    static func parse(_ text: String) -> Token? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let object = json as? [String: Any] {
                return token(fromObject: object)
            }
            if let string = (json as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                return Token(accessToken: string, expiry: nil)
            }
            return nil
        }
        // 结构化内容坏了就不当裸 token 乱发。
        if text.hasPrefix("{") || text.hasPrefix("[") { return nil }
        if text.hasPrefix("Bearer ") {
            let token = String(text.dropFirst("Bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : Token(accessToken: token, expiry: nil)
        }
        return Token(accessToken: text, expiry: nil)
    }

    private static func token(fromObject object: [String: Any]) -> Token? {
        let source = (object["token"] as? [String: Any]) ?? object
        let accessKeys = ["access_token", "accessToken", "token", "id_token", "idToken", "bearerToken"]
        let access = accessKeys.lazy
            .compactMap { (source[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let access else {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any], let token = token(fromObject: nested) {
                    return token
                }
            }
            return nil
        }
        let expiryText = ["expiry", "expires_at", "expiresAt"].lazy
            .compactMap { source[$0] as? String }
            .first
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = expiryText.flatMap { fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return Token(accessToken: access, expiry: expiry)
    }
}

/// Reads the authenticated quota service exposed by the running Antigravity
/// desktop app. The CSRF token is taken from that process's command line, kept
/// in memory only, and sent exclusively to a loopback address.
struct AntigravityLocalUsageProbe {
    struct ProcessInfo: Equatable, Sendable {
        let pid: Int
        let csrfToken: String
    }

    enum ProbeError: Error {
        case processUnavailable
        case portUnavailable
        case quotaUnavailable
    }

    private static let quotaPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let requestBody = Data(
        #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8
    )

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        let processOutput = try await ProcessRunner.run(
            "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="]
        )
        let processes = Self.parseProcesses(String(decoding: processOutput, as: UTF8.self))
        guard !processes.isEmpty else { throw ProbeError.processUnavailable }

        let delegate = AntigravityLoopbackSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var foundPort = false
        for process in processes {
            let ports = await Self.listeningPorts(pid: process.pid)
            foundPort = foundPort || !ports.isEmpty
            // Antigravity 2.x normally exposes one self-signed HTTPS port and
            // one HTTP extension port. Prefer HTTPS, then try the HTTP peer.
            for scheme in ["https", "http"] {
                for port in ports {
                    guard let data = try? await Self.requestQuota(
                        scheme: scheme,
                        port: port,
                        csrfToken: process.csrfToken,
                        session: session
                    ), let quota = try? AntigravityUsageParser.parse(data, now: now)
                    else { continue }
                    return quota
                }
            }
        }

        throw foundPort ? ProbeError.quotaUnavailable : ProbeError.portUnavailable
    }

    static func parseProcesses(_ output: String) -> [ProcessInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 2, let pid = Int(fields[0]) else { return nil }

            let command = String(fields[1])
            let lower = command.lowercased()
            let isLanguageServer = lower.contains("language_server") || lower.contains("language-server")
            let isAntigravity = lower.contains("/antigravity.app/")
                || lower.contains("--app_data_dir antigravity")
                || lower.contains("--app_data_dir=antigravity")
            guard isLanguageServer, isAntigravity,
                  let csrfToken = flag("csrf_token", in: command), !csrfToken.isEmpty
            else { return nil }
            return ProcessInfo(pid: pid, csrfToken: csrfToken)
        }
    }

    static func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else {
            return []
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let ports = regex.matches(in: output, range: range).compactMap { match -> Int? in
            guard let valueRange = Range(match.range(at: 1), in: output) else { return nil }
            return Int(output[valueRange])
        }
        return Array(Set(ports)).sorted()
    }

    private static func flag(_ name: String, in command: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: "(?:^|\\s)--\(escaped)(?:=|\\s+)([^\\s]+)"
        ) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              let valueRange = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[valueRange])
    }

    private static func listeningPorts(pid: Int) async -> [Int] {
        let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return []
        }
        guard let output = try? await ProcessRunner.run(
            executable,
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)]
        ) else { return [] }
        return parseListeningPorts(String(decoding: output, as: UTF8.self))
    }

    private static func requestQuota(
        scheme: String,
        port: Int,
        csrfToken: String,
        session: URLSession
    ) async throws -> Data {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(quotaPath)") else {
            throw ProbeError.portUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProbeError.quotaUnavailable
        }
        return data
    }
}

/// Antigravity's loopback HTTPS endpoint uses a self-signed certificate. Trust
/// is relaxed only for 127.0.0.1/localhost; all non-loopback challenges keep
/// the platform's default validation.
private final class AntigravityLoopbackSessionDelegate: NSObject,
    URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable
{
    private func disposition(
        for challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let host = space.host.lowercased()
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              host == "127.0.0.1" || host == "localhost",
              let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        disposition(for: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        disposition(for: challenge)
    }
}
