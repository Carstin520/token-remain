import Foundation
import OSLog

/// Meta Muse 个人智能体(muse.ai)的每周 token 额度。Free / Power($20,
/// 每周 500M)/ Maximum($100,每周 3B)共用一个按周重置的池;官方只给
/// 已用百分比与重置时间,不给绝对 token 数(付费档另有 "x tokens left"
/// 文案,这里不解析)。与 Muse Code CLI 是两个产品,不共用额度。
///
/// 数据源是 muse.ai 设置页自己调用的 Next.js server action
/// `fetchSubscriptionAction`(参考 CodexBar 的 museai 插件,MIT)。凭证只用
/// 用户主动粘贴、存在本应用钥匙串里的 muse.ai Cookie——**绝不读取浏览器
/// Cookie 库**,也不代为登录或续期;会话过期时提示用户重新粘贴。
///
/// action ID 随 muse.ai 每次部署变化:先用缓存的 ID,命中 "Server action not
/// found" 时重新从页面脚本里发现。发现过程只拉 muse.ai 自己的静态脚本
/// (不带 Cookie),有块数、体积上限,整次刷新受 `timeout` 约束。
struct MuseUsageService: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let origin = URL(string: "https://muse.ai")!
    /// The signed-in page; server actions are posted back to it.
    static let pageURL = URL(string: "https://muse.ai/")!
    static let dashboardURL = URL(string: "https://muse.ai/?settings_tab=general")!
    static let actionIDDefaultsKey = "tokenRemain.muse.subscriptionActionID.v1"
    static let weekMinutes = 10_080

    /// 首页最多扫描的脚本块数、设置模块最多拉取的块数、累计文本上限。
    static let maxPageChunks = 96
    static let maxSettingsChunks = 32
    static let chunkBatchSize = 8
    static let maxScannedBytes = 8 * 1024 * 1024
    static let maxResponseBytes = 4 * 1024 * 1024

    var transport: Transport = Self.network
    /// 整次刷新(含可能的 action 重新发现)的时限。
    var timeout: TimeInterval = 45
    /// action ID 不是凭证,只是 muse.ai 某次部署的函数标识,存 UserDefaults。
    var loadActionID: @Sendable () -> String? = {
        UserDefaults.standard.string(forKey: MuseUsageService.actionIDDefaultsKey)
    }
    var storeActionID: @Sendable (String?) -> Void = { value in
        if let value {
            UserDefaults.standard.set(value, forKey: MuseUsageService.actionIDDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MuseUsageService.actionIDDefaultsKey)
        }
    }

    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "MuseUsage")
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    enum ServiceError: LocalizedError, Sendable, Equatable {
        case sessionExpired
        case actionNotFound

        var errorDescription: String? {
            switch self {
            case .sessionExpired: L10n.text("service.muse.session_expired")
            case .actionNotFound: L10n.text("service.muse.action_not_found")
            }
        }
    }

    private enum ActionResult {
        case ok(Data)
        case stale
        case signedOut
    }

    func fetch(cookie suppliedCookie: String? = nil, now: Date = .now) async throws -> ProviderQuota {
        guard let raw = suppliedCookie ?? ProviderSecretStore(provider: .muse).load() else {
            throw ExtendedProviderError.notConfigured(.muse)
        }
        guard let cookie = WebCookieHeader.normalized(raw) else {
            throw ExtendedProviderError.invalidSecret(.muse, detail: L10n.text("cookieguide.invalid_cookie"))
        }
        return try await AsyncDeadline.run(timeout: timeout) {
            if let cached = loadActionID() {
                switch try await callAction(cached, cookie: cookie) {
                case .ok(let data):
                    return try Self.parse(data, now: now)
                case .signedOut:
                    throw ServiceError.sessionExpired
                case .stale:
                    break
                }
            }
            storeActionID(nil)
            guard let discovered = try await discoverActionID(cookie: cookie) else {
                throw ServiceError.sessionExpired
            }
            try Task.checkCancellation()
            switch try await callAction(discovered, cookie: cookie) {
            case .ok(let data):
                let quota = try Self.parse(data, now: now)
                storeActionID(discovered)
                Self.logger.info("Muse quota served by a rediscovered subscription action")
                return quota
            case .signedOut:
                throw ServiceError.sessionExpired
            case .stale:
                throw ServiceError.actionNotFound
            }
        }
    }

    // MARK: - Requests

    private func callAction(_ actionID: String, cookie: String) async throws -> ActionResult {
        var request = Self.request(url: Self.pageURL)
        request.httpMethod = "POST"
        request.httpBody = Data(#"[{"includeAgreement":true}]"#.utf8)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("text/x-component", forHTTPHeaderField: "Accept")
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(actionID, forHTTPHeaderField: "Next-Action")
        request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "Origin")
        // muse.ai 对不像同源浏览器请求的 server action 直接回 403。
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        let (data, response) = try await send(request)
        if Self.isSignedOut(response) { return .signedOut }
        if response.statusCode == 404,
           String(decoding: data.prefix(4096), as: UTF8.self)
               .range(of: "server action not found", options: .caseInsensitive) != nil {
            return .stale
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ExtendedProviderError.requestFailed(.muse, response.statusCode)
        }
        return .ok(data)
    }

    /// nil = muse.ai 把这个会话当作未登录。
    private func discoverActionID(cookie: String) async throws -> String? {
        var pageRequest = Self.request(url: Self.pageURL)
        pageRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        pageRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        let (page, response) = try await send(pageRequest)
        if Self.isSignedOut(response) { return nil }
        guard response.statusCode == 200 else {
            throw ExtendedProviderError.requestFailed(.muse, response.statusCode)
        }

        let paths = Array(Self.chunkPaths(in: String(decoding: page, as: UTF8.self)).prefix(Self.maxPageChunks))
        var scanned = ""
        for start in stride(from: 0, to: paths.count, by: Self.chunkBatchSize) {
            let batch = Array(paths[start..<min(start + Self.chunkBatchSize, paths.count)])
            scanned += "\n" + (await fetchChunks(batch)).joined(separator: "\n")
            guard scanned.utf8.count <= Self.maxScannedBytes else { throw ServiceError.actionNotFound }
            guard let settingsPaths = Self.settingsChunkPaths(in: scanned) else { continue }
            let limited = Array(settingsPaths.prefix(Self.maxSettingsChunks))
            for settingsStart in stride(from: 0, to: limited.count, by: Self.chunkBatchSize) {
                let settingsBatch = Array(
                    limited[settingsStart..<min(settingsStart + Self.chunkBatchSize, limited.count)]
                )
                for body in await fetchChunks(settingsBatch) {
                    if let id = Self.subscriptionActionID(in: body) { return id }
                }
            }
            break
        }
        throw ServiceError.actionNotFound
    }

    /// 静态脚本不带 Cookie;单块失败按空文本处理,由上层判定发现失败。
    private func fetchChunks(_ paths: [String]) async -> [String] {
        await withTaskGroup(of: (Int, String).self) { group in
            for (index, path) in paths.enumerated() {
                guard let url = URL(string: path, relativeTo: Self.origin)?.absoluteURL,
                      url.host == Self.origin.host else { continue }
                group.addTask {
                    var request = Self.request(url: url)
                    request.setValue("*/*", forHTTPHeaderField: "Accept")
                    guard let (data, response) = try? await send(request),
                          response.statusCode == 200 else { return (index, "") }
                    return (index, String(decoding: data, as: UTF8.self))
                }
            }
            var bodies = Array(repeating: "", count: paths.count)
            for await (index, body) in group { bodies[index] = body }
            return bodies
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard data.count <= Self.maxResponseBytes else {
                throw ExtendedProviderError.invalidResponse(.muse)
            }
            return (data, response)
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw AsyncDeadline.Failure.timedOut }
            throw error
        }
    }

    private static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 401/403,或被重定向到 auth.muse.ai 登录页(不跟随重定向)。
    static func isSignedOut(_ response: HTTPURLResponse) -> Bool {
        if response.statusCode == 401 || response.statusCode == 403 { return true }
        guard (300..<400).contains(response.statusCode) else { return false }
        let location = response.value(forHTTPHeaderField: "Location") ?? ""
        return location.isEmpty || location.hasPrefix("https://auth.muse.ai/")
            || location.hasPrefix("/")
    }

    // MARK: - Pure parsing (tested with fixtures)

    /// 页面或脚本里出现的 `static/chunks/*.js`,去重保序,转成站内绝对路径。
    static func chunkPaths(in text: String) -> [String] {
        var seen = Set<String>()
        return matches(#"static/chunks/[\w~.-]+\.js"#, in: text).compactMap { match in
            let path = "/_next/\(match)"
            return seen.insert(path).inserted ? path : nil
        }
    }

    /// 主 app 块以 `e.A(<module>).then(({preloadHatchSettingsData…` 预载设置模块;
    /// loader 块列出该模块的脚本文件。两者都扫到才返回设置模块的脚本路径。
    static func settingsChunkPaths(in text: String) -> [String]? {
        guard let module = firstCapture(#"\.A\((\d+)\)\.then\(\(\{[^}]*Settings"#, in: text),
              let files = firstCapture(
                #"[,{\[]\#(module),\w+=>\{\w+\.v\(\w+=>Promise\.all\(\[([^\]]*)"#,
                in: text
              ) else {
            return nil
        }
        return chunkPaths(in: files)
    }

    static func subscriptionActionID(in text: String) -> String? {
        firstCapture(#""([0-9a-f]{40,})",[^"]{0,200}"fetchSubscriptionAction""#, in: text)
    }

    /// React flight 响应按行 `<id>:<json>`;订阅在带 `"success":true` 的那一行。
    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        var subscription: [String: Any]?
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let json = firstCapture(#"^[0-9a-f]+:(\{.*\})\s*$"#, in: String(line)),
                  let row = ExtendedHTTP.json(Data(json.utf8)),
                  row["success"] as? Bool == true else { continue }
            subscription = row["subscription"] as? [String: Any]
        }
        guard let subscription,
              let usage = subscription["usage"] as? [String: Any],
              let percent = ExtendedHTTP.number(usage["percentUsed"]), percent.isFinite else {
            throw ExtendedProviderError.invalidResponse(.muse)
        }
        let resetsAt = ExtendedHTTP.number(usage["resetsAt"]).flatMap { seconds -> Date? in
            seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        let planName = ((subscription["tier"] as? [String: Any])?["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 加购 / 邀请奖励的 token 永不过期、独立于周额度;muse.ai 以微美元计。
        var topUp: QuotaBalance?
        if let balance = ExtendedHTTP.number(subscription["topupBalance"]),
           let total = ExtendedHTTP.number(subscription["topupTotal"]),
           balance.isFinite, total.isFinite, total > 0, balance >= 0 {
            topUp = QuotaBalance(amount: balance / 1_000_000, currencyCode: "USD")
        }

        return ProviderQuota(
            provider: .muse,
            primary: QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(percent),
                windowMinutes: weekMinutes,
                resetsAt: resetsAt
            ),
            secondary: nil,
            planName: planName?.isEmpty == false ? planName : nil,
            capturedAt: now,
            accountBalance: topUp
        )
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    // MARK: - Network

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// 不跟随重定向(登录页跳转要当成"会话过期"看见),不存 Cookie、不缓存。
    static func network(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ExtendedProviderError.invalidResponse(.muse)
        }
        return (data, response)
    }
}
