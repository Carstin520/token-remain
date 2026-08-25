import Darwin
import Foundation

/// Qoder 站点(国际版 qoder.com / 国内版 qoder.com.cn)。两站会话完全独立,
/// 一站的 Cookie 绝不能发往另一站。
enum QoderSite: String, CaseIterable, Sendable {
    case international
    case china

    var origin: String {
        switch self {
        case .international: return "https://qoder.com"
        case .china: return "https://qoder.com.cn"
        }
    }

    var usageURL: URL {
        URL(string: "\(origin)/api/v2/me/usages/big_model_credits")!
    }
}

enum QoderIPCError: Error {
    case socketUnavailable
    case timedOut
    case invalidFrame
    case responseTooLarge
    case rpcFailure(String)
}

/// Qoder 桌面端本地 JSON-RPC 服务(只读探测)。发现方式与 TokenTracker
/// `qoder-limits.js` 一致:读 `SharedClientCache/.info.json` 里的
/// `ipcServerPath`,连 Unix domain socket,发一帧
/// `Content-Length: N\r\n\r\n{jsonrpc}` 请求。只查 `credit/usage`,
/// 绝不读取或落盘 auth/status 凭据、浏览器 Cookie 或钥匙串条目。
enum QoderLocalIPC {
    struct Edition: Sendable {
        let appDir: String
        let homeEnvKey: String
    }

    /// 国际版在前:装了两个客户端时优先国际版,与 TokenTracker 同序。
    static let editions: [Edition] = [
        Edition(appDir: "Qoder", homeEnvKey: "QODER_HOME"),
        Edition(appDir: "QoderCN", homeEnvKey: "QODER_CN_HOME")
    ]

    static let maxBodyBytes = 4 * 1024 * 1024

    /// Qoder 共享客户端一次只接受一个可靠连接,并行连接会间歇超时,
    /// 所有 socket 往返都排进这条串行队列。
    private static let exchangeQueue = DispatchQueue(label: "com.jamesli.usagedock.qoder-ipc")

    static func infoFileURL(
        edition: Edition,
        home: URL,
        environment: [String: String]
    ) -> URL {
        let root: URL
        if let override = environment[edition.homeEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            root = home.appending(path: "Library/Application Support/\(edition.appDir)")
        }
        return root.appending(path: "SharedClientCache/.info.json")
    }

    /// 应用未安装/未运行(.info.json 缺失、损坏或没有端点)时返回 nil。
    static func socketPath(
        edition: Edition,
        home: URL,
        environment: [String: String]
    ) -> String? {
        guard let data = try? Data(contentsOf: infoFileURL(
            edition: edition, home: home, environment: environment
        )) else {
            return nil
        }
        return socketPath(infoData: data)
    }

    static func socketPath(infoData: Data) -> String? {
        guard let info = ExtendedHTTP.json(infoData),
              let path = (info["ipcServerPath"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    static func encodeRequest(method: String, id: Int = 1) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": [String: String]()
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        return frame
    }

    /// 增量解帧:帧未收全返回 nil,头部损坏或声明体超限则抛错。
    static func frameBody(in buffer: Data) throws -> Data? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= 8_192 else { throw QoderIPCError.invalidFrame }
            return nil
        }
        let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        guard let lengthLine = header
            .components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("content-length:") }),
            let length = Int(
                lengthLine.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
            ) else {
            throw QoderIPCError.invalidFrame
        }
        guard length >= 0, length <= maxBodyBytes else { throw QoderIPCError.responseTooLarge }
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Data(body.prefix(length))
    }

    static func rpcResult(fromFrameBody body: Data) throws -> [String: Any] {
        guard let message = ExtendedHTTP.json(body) else {
            throw QoderIPCError.invalidFrame
        }
        if let error = message["error"] as? [String: Any] {
            throw QoderIPCError.rpcFailure((error["message"] as? String) ?? "request failed")
        }
        guard let result = message["result"] as? [String: Any] else {
            throw QoderIPCError.invalidFrame
        }
        return result
    }

    /// 一次串行化的 JSON-RPC 往返;`exchange` 为测试注入点。
    static func requestResult(
        socketPath: String,
        method: String,
        exchange: @escaping (String, Data) throws -> Data = {
            try QoderLocalIPC.exchange(socketPath: $0, request: $1)
        }
    ) async throws -> [String: Any] {
        let request = encodeRequest(method: method)
        return try await withCheckedThrowingContinuation { continuation in
            exchangeQueue.async {
                continuation.resume(with: Result {
                    try rpcResult(fromFrameBody: exchange(socketPath, request))
                })
            }
        }
    }

    /// 阻塞式 socket 往返(仅在串行队列上调用):连接、写一帧、读到
    /// 整帧即返回。收发都受 `timeout` 约束,结束即关闭连接。
    static func exchange(
        socketPath: String,
        request: Data,
        timeout: TimeInterval = 1.5
    ) throws -> Data {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard !pathBytes.isEmpty, pathBytes.count <= capacity else {
            throw QoderIPCError.socketUnavailable
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw QoderIPCError.socketUnavailable }
        defer { close(fd) }
        // A Qoder restart can close the peer between connect and send. Prevent
        // Darwin from delivering SIGPIPE to the whole menu-bar process.
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: suseconds_t(timeout.truncatingRemainder(dividingBy: 1) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw QoderIPCError.socketUnavailable }

        try request.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { throw QoderIPCError.socketUnavailable }
            var sent = 0
            while sent < raw.count {
                let written = write(fd, base + sent, raw.count - sent)
                guard written > 0 else { throw QoderIPCError.timedOut }
                sent += written
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { throw QoderIPCError.timedOut }
            buffer.append(contentsOf: chunk[0..<count])
            if let body = try frameBody(in: buffer) { return body }
            guard buffer.count <= maxBodyBytes + 16_384 else {
                throw QoderIPCError.responseTooLarge
            }
            guard Date() < deadline else { throw QoderIPCError.timedOut }
        }
    }
}

// MARK: - Qoder(本地 IPC 优先,Cookie 兜底)

/// 取数顺序:① 手动 Cookie 走 `GET {site}/api/v2/me/usages/big_model_credits`
/// (按 Cookie 来源路由国际/国内站并带齐浏览器同款请求头);② 没配 Cookie
/// 或 Cookie 请求失败时,退回本地 IPC 自动发现(Qoder → QoderCN,
/// `credit/usage`)。Cookie 在前是实测结论(#18):付费账号的 IPC
/// `credit/usage` 与网页 Credits 仪表盘不是同一口径(实测 99.9% vs
/// 89.9% 剩余),用户显式提供的 Cookie 才对得上账单页。
/// 两条路径都不落盘、不打日志任何凭据。
struct QoderUsageService {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var environment: [String: String] = ProcessInfo.processInfo.environment
    /// 测试注入:一次 socket 帧往返(入参整帧请求,返回解帧后的响应体)。
    var ipcExchange: (String, Data) throws -> Data = {
        try QoderLocalIPC.exchange(socketPath: $0, request: $1)
    }
    /// 测试注入:手动 Cookie 密钥读取。
    var loadCookie: () -> String? = { ProviderSecretStore(provider: .qoder).load() }
    /// 测试注入:HTTP 请求。
    var httpRequest: (URL, [String: String]) async throws -> Data = { url, headers in
        try await ExtendedHTTP.request(.qoder, url: url, headers: headers)
    }

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(cookie: nil, now: now)
    }

    func fetch(cookie routedCookie: String?, now: Date = .now) async throws -> ProviderQuota {
        if let raw = routedCookie ?? loadCookie(),
           let credentials = Self.cookieCredentials(raw, environment: environment) {
            do {
                let data = try await httpRequest(
                    credentials.site.usageURL,
                    Self.requestHeaders(cookie: credentials.cookie, site: credentials.site)
                )
                return try Self.parse(data, now: now)
            } catch {
                // 显式路由到某个账户的 Cookie 失败时绝不换池——那会把
                // 另一个账户(本机登录)的数字冒充给这个账户。全局默认
                // 路径则允许退回 IPC,Cookie 过期时卡片仍有数可看。
                guard routedCookie == nil else { throw error }
                if let quota = await localQuota(now: now) { return quota }
                throw error
            }
        }
        if routedCookie == nil, let quota = await localQuota(now: now) { return quota }
        throw ExtendedProviderError.notConfigured(.qoder)
    }

    /// 本地 IPC 自动发现。任一环节失败(未安装、未运行、响应异常)都
    /// 静默放弃,交给手动 Cookie 兜底。
    func localQuota(now: Date) async -> ProviderQuota? {
        for edition in QoderLocalIPC.editions {
            guard let socketPath = QoderLocalIPC.socketPath(
                edition: edition, home: home, environment: environment
            ) else {
                continue
            }
            do {
                let result = try await QoderLocalIPC.requestResult(
                    socketPath: socketPath,
                    method: "credit/usage",
                    exchange: ipcExchange
                )
                return try Self.parseRPCQuota(result, now: now)
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: 本地 IPC 响应

    /// Qoder 免费账号以 9999-12-31 作"永不过期"哨兵,2100 年起一律视为无重置日。
    static let noExpirySentinel = Date(timeIntervalSince1970: 4_102_444_800)

    /// `credit/usage` 结果:`userQuota{used,total,remaining,percentage}` +
    /// `userType` / `expiresAt` / `isQuotaExceeded`。total 为 0 的空计划按
    /// Qoder Credits 界面口径渲染 0%,不渲染爆表 100%。
    static func parseRPCQuota(_ result: [String: Any], now: Date = .now) throws -> ProviderQuota {
        guard let quota = result["userQuota"] as? [String: Any],
              let used = ExtendedHTTP.number(quota["used"]),
              let total = ExtendedHTTP.number(quota["total"]),
              used >= 0, total >= 0 else {
            throw ExtendedProviderError.invalidResponse(.qoder)
        }
        let remaining = ExtendedHTTP.number(quota["remaining"]) ?? max(0, total - used)
        guard remaining >= 0 else {
            throw ExtendedProviderError.invalidResponse(.qoder)
        }
        // `totalUsagePercentage` / `userQuota.percentage` 不可信(#18):付费
        // 账号实测它与网页 Credits 仪表盘差两个数量级(0.1% vs 10.1% 已用),
        // 疑似跨池汇总或另一种刻度。具体计数器 used/total 与 Credits 界面
        // 同源,始终按它计算。
        let percent: Double
        if total == 0 {
            percent = 0
        } else if result["isQuotaExceeded"] as? Bool == true {
            percent = 100
        } else {
            percent = used / total * 100
        }
        let userType = (result["userType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderQuota(
            provider: .qoder,
            primary: QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(percent),
                windowMinutes: 43_200,
                resetsAt: expiryDate(result["expiresAt"])
            ),
            secondary: nil,
            planName: userType?.isEmpty == false ? userType : nil,
            capturedAt: now
        )
    }

    static func expiryDate(_ value: Any?) -> Date? {
        let date: Date?
        if let epoch = ExtendedHTTP.number(value), epoch > 0 {
            date = Date(timeIntervalSince1970: epoch > 1e10 ? epoch / 1000 : epoch)
        } else if let text = value as? String, !text.isEmpty {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        } else {
            date = nil
        }
        guard let date, date < noExpirySentinel else { return nil }
        return date
    }

    // MARK: 手动 Cookie

    struct CookieCredentials: Equatable {
        let cookie: String
        let site: QoderSite
    }

    /// 归一化粘贴内容(整段 Cookie 或 curl 拷贝)并判定站点。只有 curl
    /// 请求 URL 可以固定站点;普通 Cookie 值中的域名不能参与路由,避免
    /// 把一站的会话误发给另一站。其余情况看 QODER_SITE,默认国际站。
    static func cookieCredentials(
        _ raw: String,
        environment: [String: String] = [:]
    ) -> CookieCredentials? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let cookieText = extractCookieText(from: text)
        guard let cookie = normalizedCookieHeader(cookieText) else { return nil }
        return CookieCredentials(cookie: cookie, site: detectSite(in: text, environment: environment))
    }

    static func detectSite(in text: String, environment: [String: String]) -> QoderSite {
        if let curlSite = curlSite(in: text) { return curlSite }
        let hint = environment["QODER_SITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if hint == "cn" || hint == "china" || hint.contains(".cn") { return .china }
        return .international
    }

    private static func curlSite(in text: String) -> QoderSite? {
        guard text.lowercased().contains("curl"),
              let regex = try? NSRegularExpression(
                  pattern: #"https?://[^\s'\"]+"#,
                  options: [.caseInsensitive]
              ) else {
            return nil
        }
        // A curl command may put -H before its request URL. Remove the captured
        // Cookie value before scanning URLs so a URL-shaped cookie value cannot
        // select the destination host.
        let routingText: String
        if let cookie = curlCookieValue(in: text) {
            routingText = text.replacingOccurrences(of: cookie, with: "")
        } else {
            routingText = text
        }
        let range = NSRange(routingText.startIndex..., in: routingText)
        var detected: Set<QoderSite> = []
        for match in regex.matches(in: routingText, range: range) {
            guard let matchRange = Range(match.range, in: routingText),
                  let host = URL(string: String(routingText[matchRange]))?.host()?.lowercased() else {
                continue
            }
            if host == "qoder.com.cn" || host == "www.qoder.com.cn" { detected.insert(.china) }
            if host == "qoder.com" || host == "www.qoder.com" { detected.insert(.international) }
        }
        return detected.count == 1 ? detected.first : nil
    }

    /// curl 拷贝取 `-H 'cookie: …'` / `-b '…'`;普通粘贴剥掉可选 "Cookie:" 前缀。
    static func extractCookieText(from text: String) -> String {
        if let captured = curlCookieValue(in: text) { return captured }
        var value = text
        if let range = value.range(
            of: #"^\s*cookie\s*:"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            value = String(value[range.upperBound...])
        }
        return value
    }

    private static func curlCookieValue(in text: String) -> String? {
        guard text.lowercased().contains("curl") else { return nil }
        let patterns = [
            #"-H\s+\$?'cookie:\s*([^']*)'"#,
            #"-H\s+\$?"cookie:\s*([^"]*)""#,
            #"(?:-b|--cookie)\s+\$?'([^']*)'"#,
            #"(?:-b|--cookie)\s+\$?"([^"]*)""#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// 拆成 name=value 对再重组,顺带清掉换行/续行符。没有任何键值对时
    /// 原样发送修剪后的文本,由服务端 401 给出"凭据被拒"的明确提示。
    static func normalizedCookieHeader(_ raw: String) -> String? {
        let flattened = raw
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let pairs = flattened.split(separator: ";").compactMap { component -> String? in
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return "\(name)=\(value)"
        }
        if pairs.isEmpty {
            let fallback = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? nil : fallback
        }
        return pairs.joined(separator: "; ")
    }

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    /// 按 TokenTracker / CodexBar 的已验证实现补齐浏览器同款请求头。
    static func requestHeaders(cookie: String, site: QoderSite) -> [String: String] {
        [
            "Cookie": cookie,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "User-Agent": userAgent,
            "Origin": site.origin,
            "Referer": "\(site.origin)/account/usage",
            "X-Requested-With": "XMLHttpRequest",
            "Bx-V": "2.5.35"
        ]
    }

    /// 与 Qoder 控制台"我的额度 / 团队共享"两栏一致的池名;
    /// scopeID 需满足 sync 的 [a-z0-9_-]{1,32} 约束。
    static let personalPoolName = "Personal"
    static let personalPoolScopeID = "qoder_personal"
    static let sharedPoolName = "Shared"
    static let sharedPoolScopeID = "qoder_shared"

    /// `totalQuota.quotaSummary{usedValue,limitValue}`(个人池)+ 可选
    /// `sharedQuota`(团队共享池)。两池独立计费,绝不求和——个人池耗尽
    /// 而共享池未动时,求和会把 100% 稀释成"还剩很多",掩盖真正的瓶颈。
    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data) else {
            throw ExtendedProviderError.invalidResponse(.qoder)
        }
        let payload = (body["data"] as? [String: Any]) ?? body
        func summary(_ key: String, _ snakeKey: String) -> (used: Double, total: Double)? {
            guard let container = (payload[key] ?? payload[snakeKey]) as? [String: Any],
                  let quotaSummary = (container["quotaSummary"] ?? container["quota_summary"]) as? [String: Any],
                  let used = ExtendedHTTP.number(quotaSummary["usedValue"] ?? quotaSummary["used_value"]),
                  let total = ExtendedHTTP.number(quotaSummary["limitValue"] ?? quotaSummary["limit_value"]),
                  used >= 0, total >= 0 else {
                return nil
            }
            return (used, total)
        }
        guard let total = summary("totalQuota", "total_quota") else {
            throw ExtendedProviderError.invalidResponse(.qoder)
        }
        let shared = summary("sharedQuota", "shared_quota")

        typealias Pool = (name: String, scopeID: String, usedPercent: Double)
        func pool(_ name: String, _ scopeID: String, _ values: (used: Double, total: Double)?) -> Pool? {
            // 零上限的池不参与展示:免费/无团队账号的 sharedQuota 常是 0/0 占位。
            guard let values, values.total > 0 else { return nil }
            return (name, scopeID, ExtendedHTTP.clamp(values.used / values.total * 100))
        }
        let personalPool = pool(personalPoolName, personalPoolScopeID, total)
        let sharedPool = pool(sharedPoolName, sharedPoolScopeID, shared)

        func singlePool(_ only: Pool) -> ProviderQuota {
            // 单池维持历史形态:一条主窗口,不带 poolName。
            ProviderQuota(
                provider: .qoder,
                primary: QuotaWindow(
                    usedPercent: only.usedPercent,
                    windowMinutes: 43_200,
                    resetsAt: nil
                ),
                secondary: nil,
                planName: nil,
                capturedAt: now
            )
        }

        switch (personalPool, sharedPool) {
        case (nil, nil):
            throw ExtendedProviderError.invalidResponse(.qoder)
        case (let only?, nil), (nil, let only?):
            return singlePool(only)
        case (let personal?, let team?):
            // 双池走 Cursor 约定:较忙的池(已用百分比更高者,即真正的瓶颈)
            // 做 primary 并带 poolName,另一池以命名 scoped 窗口展示。不走
            // `secondary`:两池同为 43200 分钟的账户级窗口,手机同步的
            // duplicateWindow 校验会拒收第二个,scoped 则允许。
            let (busier, other) = team.usedPercent > personal.usedPercent
                ? (team, personal)
                : (personal, team)
            return ProviderQuota(
                provider: .qoder,
                primary: QuotaWindow(
                    usedPercent: busier.usedPercent,
                    windowMinutes: 43_200,
                    resetsAt: nil,
                    poolName: busier.name
                ),
                secondary: nil,
                planName: nil,
                capturedAt: now,
                scopedWindows: [
                    ScopedQuotaWindow(
                        scopeID: other.scopeID,
                        displayName: other.name,
                        window: QuotaWindow(
                            usedPercent: other.usedPercent,
                            windowMinutes: 43_200,
                            resetsAt: nil
                        ),
                        observedAt: now
                    )
                ]
            )
        }
    }
}
