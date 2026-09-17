import CFNetwork
import Foundation
import OSLog

/// 决定 PTY 探针(以及 `auth status`)用哪条网络路线跑 Claude CLI。
///
/// 探针的全部价值是让 CLI 自己续期,而 CLI 的 Node 网络栈只认
/// `HTTPS_PROXY` 这类环境变量。GUI 进程既没有 shell 里的代理变量,也
/// 不一定开着系统代理:用本地代理软件的用户经常只在 shell 里 export,或
/// 者把代理写进 Claude Code 自己的 settings.json。任何一处漏掉,探针就
/// 在每次到期时白等 45 秒,再把网络问题报成"读取超时"。
///
/// 这里把所有已知来源列成候选,按优先级并发做一次可达性预检,只把真
/// 正能连到 api.anthropic.com 的那组变量交给探针;一条都不通就不启动
/// 探针,让调用方保留缓存、稍后再试。
enum ClaudeProbeNetworkEnvironment {
    static let proxyKeys = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy"
    ]

    struct Candidate: Equatable, Sendable {
        let source: String
        /// 只含代理变量;空字典表示直连。
        let proxyVariables: [String: String]
    }

    /// 预检目标。任何 HTTP 响应(包括 401)都证明链路通;鉴权由后续请求负责。
    static let reachabilityURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let reachabilityTimeout: TimeInterval = 5
    static let shellCaptureTimeout: TimeInterval = 4
    static let shellCacheLifetime: TimeInterval = 10 * 60
    /// PAC fetch/evaluation (5 + 3s), shell capture (4s), route checks (5s).
    /// The provider's existing overall deadline also covers this phase.
    static let resolutionTimeout: TimeInterval = 18

    // MARK: - Candidate assembly (pure)

    /// 候选顺序即优先级:进程里已有的显式变量 → Claude Code settings.json
    /// 的 `env` → 系统代理 → 登录 shell 导出的变量 → 直连。相同的一组变量
    /// 只保留最先出现的来源。
    static func candidates(
        base: [String: String],
        claudeSettingsEnvironment: [String: String],
        systemProxySettings: [String: Any]?,
        pacProxyVariables: [String: String]? = nil,
        shellEnvironment: [String: String]
    ) -> [Candidate] {
        var result: [Candidate] = []
        func append(_ source: String, _ variables: [String: String]) {
            let normalized = proxyVariables(in: variables)
            // 只有 NO_PROXY 而没有任何代理地址(例如系统只开了 PAC,却带着
            // 例外列表)的一组变量,实际就是直连,不单独占一条候选。
            guard source == "direct" || hasProxyEndpoint(normalized) else { return }
            guard !result.contains(where: { $0.proxyVariables == normalized }) else { return }
            result.append(Candidate(source: source, proxyVariables: normalized))
        }

        let explicit = proxyVariables(in: base)
        if !explicit.isEmpty { append("process", explicit) }

        let fromSettings = proxyVariables(in: claudeSettingsEnvironment)
        if !fromSettings.isEmpty { append("claude-settings", fromSettings) }

        if let systemProxySettings {
            let system = proxyVariables(
                in: SystemProxyEnvironment.applying(systemProxySettings, to: [:])
            )
            if !system.isEmpty { append("system", system) }
        }

        // PAC 的结果可能就是 DIRECT:那也是一条明确的系统路线,和兜底的
        // 直连语义相同,靠去重合并即可。
        if let pacProxyVariables, !pacProxyVariables.isEmpty {
            append("system-pac", pacProxyVariables)
        }

        let fromShell = proxyVariables(in: shellEnvironment)
        if !fromShell.isEmpty { append("shell", fromShell) }

        append("direct", [:])
        return result
    }

    static func hasProxyEndpoint(_ variables: [String: String]) -> Bool {
        ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
            .contains { variables[$0] != nil }
    }

    static func proxyVariables(in environment: [String: String]) -> [String: String] {
        environment.filter { key, value in
            proxyKeys.contains(key)
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// `env` 的输出按行拆成键值,只保留代理变量。交互式 shell 可能在前面
    /// 打印提示或警告,没有 `=` 的行直接忽略。
    static func proxyVariables(fromShellOutput output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            guard proxyKeys.contains(key) else { continue }
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[key] = value }
        }
        return result
    }

    /// Claude Code 自己会应用 settings.json 的 `env`,这里读它只是为了让
    /// 预检知道 CLI 实际会走哪条路。
    static func claudeSettingsEnvironment(
        configurationDirectory: URL,
        fileManager: FileManager = .default
    ) -> [String: String] {
        var merged: [String: String] = [:]
        for name in ["settings.json", "settings.local.json"] {
            let url = configurationDirectory.appending(path: name)
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let env = object["env"] as? [String: Any] else {
                continue
            }
            for (key, value) in env {
                if let text = value as? String { merged[key] = text }
            }
        }
        return proxyVariables(in: merged)
    }

    /// 把一组代理变量翻译成 URLSession 的 `connectionProxyDictionary`。
    /// 空字典 = 直连(显式关闭系统代理,预检才能区分"系统代理通"和"直连通")。
    static func proxyDictionary(for proxyVariables: [String: String]) -> [AnyHashable: Any] {
        var dictionary: [AnyHashable: Any] = [:]
        let https = proxyVariables["HTTPS_PROXY"] ?? proxyVariables["https_proxy"]
            ?? proxyVariables["ALL_PROXY"] ?? proxyVariables["all_proxy"]
            ?? proxyVariables["HTTP_PROXY"] ?? proxyVariables["http_proxy"]
        guard let https, let endpoint = endpoint(from: https) else {
            return dictionary
        }
        if endpoint.isSOCKS {
            dictionary[kCFNetworkProxiesSOCKSEnable] = 1
            dictionary[kCFNetworkProxiesSOCKSProxy] = endpoint.host
            dictionary[kCFNetworkProxiesSOCKSPort] = endpoint.port
        } else {
            dictionary[kCFNetworkProxiesHTTPSEnable] = 1
            dictionary[kCFNetworkProxiesHTTPSProxy] = endpoint.host
            dictionary[kCFNetworkProxiesHTTPSPort] = endpoint.port
            dictionary[kCFNetworkProxiesHTTPEnable] = 1
            dictionary[kCFNetworkProxiesHTTPProxy] = endpoint.host
            dictionary[kCFNetworkProxiesHTTPPort] = endpoint.port
        }
        return dictionary
    }

    struct Endpoint: Equatable {
        let host: String
        let port: Int
        let isSOCKS: Bool
    }

    /// 接受 `http://host:port`、`socks5://host:port`、`host:port`。
    static func endpoint(from text: String) -> Endpoint? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else {
            return nil
        }
        let scheme = (components.scheme ?? "http").lowercased()
        let isSOCKS = scheme.hasPrefix("socks")
        let port = components.port ?? (isSOCKS ? 1080 : (scheme == "https" ? 443 : 80))
        return Endpoint(host: host, port: port, isSOCKS: isSOCKS)
    }

    /// 并发预检所有候选,再按优先级取第一条可达的。总耗时不超过一次
    /// 预检超时,而不是候选数 × 超时。
    static func firstReachable(
        _ candidates: [Candidate],
        timeout: TimeInterval = reachabilityTimeout,
        check: @escaping @Sendable (Candidate) async -> Bool
    ) async -> Candidate? {
        guard !candidates.isEmpty, !Task.isCancelled else { return nil }
        let outcomes = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    let reachable = try? await AsyncDeadline.run(timeout: timeout) {
                        await check(candidate)
                    }
                    return (index, reachable == true)
                }
            }
            var collected: [Int: Bool] = [:]
            for await (index, reachable) in group {
                collected[index] = reachable
            }
            return collected
        }
        guard !Task.isCancelled else { return nil }
        return candidates.enumerated().first { outcomes[$0.offset] == true }?.element
    }

    // MARK: - PAC

    static let pacFetchTimeout: TimeInterval = 5
    static let pacEvaluationTimeout: TimeInterval = 3

    /// 系统代理只配了 PAC 时,`HTTPEnable`/`HTTPSEnable` 都是 0,Node 也
    /// 不会自己去执行脚本。这里替 CLI 执行一次:拿到脚本(内联或按 URL
    /// 取回,取回时禁用代理避免自指),用 CFNetwork 对目标地址求值,把第
    /// 一条 PROXY/SOCKS 结果翻译成环境变量。
    static func pacProxyVariables(
        systemProxySettings: [String: Any],
        targetURL: URL = reachabilityURL
    ) async -> [String: String]? {
        guard (systemProxySettings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true else {
            return nil
        }
        let script: String
        if let inline = (systemProxySettings["ProxyAutoConfigJavaScript"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !inline.isEmpty {
            script = inline
        } else if let urlText = (systemProxySettings["ProxyAutoConfigURLString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: urlText),
            let fetched = await fetchPACScript(at: url) {
            script = fetched
        } else {
            return nil
        }
        guard var variables = await evaluatePAC(script: script, targetURL: targetURL) else {
            return nil
        }
        if !variables.isEmpty {
            let exclusions = (systemProxySettings["ExceptionsList"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ",") ?? ""
            if !exclusions.isEmpty {
                variables["NO_PROXY"] = exclusions
                variables["no_proxy"] = exclusions
            }
        }
        return variables
    }

    static func fetchPACScript(at url: URL) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = pacFetchTimeout
        configuration.timeoutIntervalForResource = pacFetchTimeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("FindProxyForURL") ? text : nil
    }

    /// CFNetwork 的求值是同步的,脚本里的 `dnsResolve` 可能卡在解析上;
    /// 放到独立任务里并设上限,超时就当 PAC 不可用。
    static func evaluatePAC(script: String, targetURL: URL) async -> [String: String]? {
        await ClaudePACEvaluator.shared.variables(
            script: script, targetURL: targetURL, timeout: pacEvaluationTimeout
        ) { script, target in
            var error: Unmanaged<CFError>?
            let result = CFNetworkCopyProxiesForAutoConfigurationScript(
                script as CFString, target as CFURL, &error
            )?.takeRetainedValue()
            guard let proxies = result as? [[String: Any]] else { return nil }
            return proxyVariables(fromPACProxies: proxies)
        }
    }

    /// PAC 返回列表按优先级排列;取第一条能表达成环境变量的。`DIRECT`
    /// 在前就是直连(空字典),整条都没有可用项返回空字典。
    static func proxyVariables(fromPACProxies proxies: [[String: Any]]) -> [String: String] {
        for proxy in proxies {
            guard let type = proxy[kCFProxyTypeKey as String] as? String else { continue }
            if type == (kCFProxyTypeNone as String) { return [:] }
            guard let host = proxy[kCFProxyHostNameKey as String] as? String, !host.isEmpty else {
                continue
            }
            let port = (proxy[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue
            if type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String) {
                let url = "http://\(host):\(port ?? 80)"
                return [
                    "HTTP_PROXY": url, "http_proxy": url,
                    "HTTPS_PROXY": url, "https_proxy": url
                ]
            }
            if type == (kCFProxyTypeSOCKS as String) {
                let url = "socks5://\(host):\(port ?? 1080)"
                return ["ALL_PROXY": url, "all_proxy": url]
            }
        }
        return [:]
    }

    // MARK: - Live resolution

    /// 返回探针应当合并进环境的代理变量;`nil` 表示没有任何路线能连到
    /// Claude,不值得启动探针。
    static func resolve(
        base: [String: String] = ProcessInfo.processInfo.environment,
        configurationDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> [String: String]? {
        try? await AsyncDeadline.run(timeout: resolutionTimeout) {
            await resolveWithinBudget(
                base: base, configurationDirectory: configurationDirectory, homeDirectory: homeDirectory
            )
        }
    }

    private static func resolveWithinBudget(
        base: [String: String], configurationDirectory: URL?, homeDirectory: URL
    ) async -> [String: String]? {
        guard !Task.isCancelled else { return nil }
        let logger = Logger(subsystem: "com.jamesli.usagedock", category: "ClaudeProbeNetwork")
        let settingsDirectory = configurationDirectory
            ?? base["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? homeDirectory.appending(path: ".claude")
        let systemProxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
        let candidates = candidates(
            base: base,
            claudeSettingsEnvironment: claudeSettingsEnvironment(configurationDirectory: settingsDirectory),
            systemProxySettings: systemProxySettings,
            pacProxyVariables: systemProxySettings == nil
                ? nil
                : await pacProxyVariables(systemProxySettings: systemProxySettings!),
            shellEnvironment: await ShellProxyCapture.shared.proxyVariables(base: base)
        )
        guard !Task.isCancelled else { return nil }
        let chosen = await firstReachable(candidates) { candidate in
            await isReachable(proxyVariables: candidate.proxyVariables)
        }
        if let chosen {
            logger.notice("Claude probe network route: \(chosen.source, privacy: .public) (\(candidates.count, privacy: .public) candidates)")
            return chosen.proxyVariables
        }
        logger.notice("Claude probe skipped: no route reaches api.anthropic.com (\(candidates.map(\.source).joined(separator: ","), privacy: .public))")
        return nil
    }

    static func isReachable(proxyVariables: [String: String]) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = proxyDictionary(for: proxyVariables)
        configuration.timeoutIntervalForRequest = reachabilityTimeout
        configuration.timeoutIntervalForResource = reachabilityTimeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: reachabilityURL)
        request.httpMethod = "GET"
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}

/// 登录 shell 的代理变量。启动一次交互式登录 shell 要读完全部 rc 文件,
/// 花几百毫秒到几秒,所以缓存十分钟;探针本来就只在 token 到期时才跑。
actor ShellProxyCapture {
    static let shared = ShellProxyCapture()

    private var cached: [String: String]?
    private var capturedAt: Date?

    func proxyVariables(base: [String: String], now: Date = .now) async -> [String: String] {
        guard !Task.isCancelled else { return [:] }
        if let cached, let capturedAt,
           now.timeIntervalSince(capturedAt) < ClaudeProbeNetworkEnvironment.shellCacheLifetime {
            return cached
        }
        let captured = await Self.capture(base: base)
        guard !Task.isCancelled else { return [:] }
        cached = captured
        capturedAt = now
        return captured
    }

    static func shellExecutable(base: [String: String]) -> String {
        if let shell = base["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    private static func capture(base: [String: String]) async -> [String: String] {
        var environment = base
        environment["TERM"] = "dumb"
        do {
            let data = try await ProcessRunner.run(
                shellExecutable(base: base),
                // `-i` 才会读 .zshrc / .bashrc,代理 export 通常写在那里。
                arguments: ["-ilc", "env"],
                environment: environment,
                timeout: ClaudeProbeNetworkEnvironment.shellCaptureTimeout
            )
            return ClaudeProbeNetworkEnvironment.proxyVariables(
                fromShellOutput: String(decoding: data, as: UTF8.self)
            )
        } catch {
            return [:]
        }
    }
}

/// CFNetwork's synchronous PAC evaluation cannot be forcibly cancelled. The
/// deadline releases the caller and discards its late result; one in-flight
/// evaluation per instance prevents retries from accumulating blocked workers.
final class ClaudePACEvaluator: @unchecked Sendable {
    static let shared = ClaudePACEvaluator()
    private let lock = NSLock()
    private var running = false

    func variables(
        script: String, targetURL: URL, timeout: TimeInterval,
        evaluate: @escaping @Sendable (String, URL) -> [String: String]?
    ) async -> [String: String]? {
        try? await AsyncDeadline.run(timeout: timeout) { [self] in
            guard begin() else { return nil }
            defer { end() }
            try Task.checkCancellation()
            return evaluate(script, targetURL)
        }
    }

    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func end() {
        lock.lock(); defer { lock.unlock() }
        running = false
    }
}
