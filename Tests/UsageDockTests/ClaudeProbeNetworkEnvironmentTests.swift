import CFNetwork
import Foundation
import Testing
@testable import UsageDock

@Suite("Claude probe network route selection")
struct ClaudeProbeNetworkEnvironmentTests {
    @Test("Candidates follow process, Claude settings, system, shell, then direct")
    func candidateOrder() {
        let candidates = ClaudeProbeNetworkEnvironment.candidates(
            base: ["HTTPS_PROXY": "http://127.0.0.1:1", "TERM": "xterm"],
            claudeSettingsEnvironment: ["HTTPS_PROXY": "http://127.0.0.1:2"],
            systemProxySettings: [
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 3
            ],
            shellEnvironment: ["https_proxy": "http://127.0.0.1:4", "PATH": "/x"]
        )
        #expect(candidates.map(\.source) == ["process", "claude-settings", "system", "shell", "direct"])
        #expect(candidates[0].proxyVariables == ["HTTPS_PROXY": "http://127.0.0.1:1"])
        #expect(candidates[2].proxyVariables["HTTPS_PROXY"] == "http://127.0.0.1:3")
        #expect(candidates[3].proxyVariables == ["https_proxy": "http://127.0.0.1:4"])
        #expect(candidates[4].proxyVariables.isEmpty)
    }

    @Test("A source that only sets NO_PROXY is not a route of its own")
    func noProxyOnlyIsDirect() {
        let candidates = ClaudeProbeNetworkEnvironment.candidates(
            base: ["NO_PROXY": "localhost"],
            claudeSettingsEnvironment: [:],
            systemProxySettings: ["ProxyAutoConfigEnable": 1, "ExceptionsList": ["*.local"]],
            shellEnvironment: ["no_proxy": "localhost"]
        )
        #expect(candidates.map(\.source) == ["direct"])
    }

    @Test("Identical proxy sets collapse onto the first source; direct is always last")
    func candidateDeduplication() {
        let candidates = ClaudeProbeNetworkEnvironment.candidates(
            base: [:],
            claudeSettingsEnvironment: [:],
            systemProxySettings: [
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890
            ],
            shellEnvironment: [
                "HTTPS_PROXY": "http://127.0.0.1:7890", "https_proxy": "http://127.0.0.1:7890",
                "HTTP_PROXY": "http://127.0.0.1:7890", "http_proxy": "http://127.0.0.1:7890"
            ]
        )
        #expect(candidates.map(\.source) == ["system", "direct"])
    }

    @Test("Shell env output keeps only proxy variables and ignores rc chatter")
    func shellOutputParsing() {
        let output = """
        Last login: today
        PATH=/opt/homebrew/bin:/usr/bin
        HTTPS_PROXY=http://127.0.0.1:7890
        no_proxy=localhost,127.0.0.1
        ALL_PROXY=
        warning: something without equals
        """
        let variables = ClaudeProbeNetworkEnvironment.proxyVariables(fromShellOutput: output)
        #expect(variables == [
            "HTTPS_PROXY": "http://127.0.0.1:7890",
            "no_proxy": "localhost,127.0.0.1"
        ])
    }

    @Test("Proxy URLs map to HTTPS or SOCKS session dictionaries; direct disables proxies")
    func proxyDictionaries() {
        let http = ClaudeProbeNetworkEnvironment.proxyDictionary(for: ["https_proxy": "http://127.0.0.1:7890"])
        #expect(http[kCFNetworkProxiesHTTPSProxy] as? String == "127.0.0.1")
        #expect(http[kCFNetworkProxiesHTTPSPort] as? Int == 7890)
        #expect(http[kCFNetworkProxiesSOCKSEnable] == nil)

        let socks = ClaudeProbeNetworkEnvironment.proxyDictionary(for: ["ALL_PROXY": "socks5://127.0.0.1:1080"])
        #expect(socks[kCFNetworkProxiesSOCKSProxy] as? String == "127.0.0.1")
        #expect(socks[kCFNetworkProxiesSOCKSPort] as? Int == 1080)
        #expect(socks[kCFNetworkProxiesHTTPSEnable] == nil)

        let bare = ClaudeProbeNetworkEnvironment.endpoint(from: "proxy.local:3128")
        #expect(bare == ClaudeProbeNetworkEnvironment.Endpoint(host: "proxy.local", port: 3128, isSOCKS: false))
        #expect(ClaudeProbeNetworkEnvironment.endpoint(from: "socks5h://127.0.0.1") ==
            ClaudeProbeNetworkEnvironment.Endpoint(host: "127.0.0.1", port: 1080, isSOCKS: true))
        #expect(ClaudeProbeNetworkEnvironment.endpoint(from: "   ") == nil)
        #expect(ClaudeProbeNetworkEnvironment.proxyDictionary(for: [:]).isEmpty)
    }

    @Test("The highest-priority reachable route wins even if a later one answers first")
    func firstReachableHonoursPriority() async {
        let candidates = [
            ClaudeProbeNetworkEnvironment.Candidate(source: "process", proxyVariables: ["HTTPS_PROXY": "http://dead:1"]),
            ClaudeProbeNetworkEnvironment.Candidate(source: "system", proxyVariables: ["HTTPS_PROXY": "http://ok:2"]),
            ClaudeProbeNetworkEnvironment.Candidate(source: "direct", proxyVariables: [:])
        ]
        let chosen = await ClaudeProbeNetworkEnvironment.firstReachable(candidates) { candidate in
            if candidate.source == "direct" { return true }
            if candidate.source == "system" {
                try? await Task.sleep(for: .milliseconds(30))
                return true
            }
            return false
        }
        #expect(chosen?.source == "system")

        let none = await ClaudeProbeNetworkEnvironment.firstReachable(candidates) { _ in false }
        #expect(none == nil)
    }

    @Test("Claude settings.json env proxies are read, local settings override")
    func claudeSettingsEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenremain-claude-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"env": {"HTTPS_PROXY": "http://127.0.0.1:1", "OTHER": "x"}}"#.utf8)
            .write(to: directory.appending(path: "settings.json"))
        try Data(#"{"env": {"HTTPS_PROXY": "http://127.0.0.1:2"}}"#.utf8)
            .write(to: directory.appending(path: "settings.local.json"))
        let variables = ClaudeProbeNetworkEnvironment.claudeSettingsEnvironment(configurationDirectory: directory)
        #expect(variables == ["HTTPS_PROXY": "http://127.0.0.1:2"])
    }

    @Test("A renewal watch flips once and stays flipped")
    func renewalWatch() {
        let watch = ClaudeProbeRenewalWatch()
        #expect(!watch.renewed)
        watch.markRenewed()
        #expect(watch.renewed)
    }

    @Test("An unreachable network never asks the user to sign in and retries sooner than a probe failure")
    func unreachableClassification() {
        let error = ClaudeUsageService.ServiceError.networkUnreachable
        #expect(!ProviderSessionAlerts.requiresSignIn(error))
        #expect(error.isTransportFailure)
        #expect(error.retryDelay < ClaudeUsageService.ServiceError.cliTimedOut.retryDelay)
        #expect(!ClaudeUsageService.ServiceError.cliTimedOut.isTransportFailure)
    }
}

// These integration cases share the process-wide native PAC evaluator, which
// deliberately allows only one outstanding synchronous evaluation. Its busy,
// timeout and cancellation behavior is covered separately with owned instances.
@Suite("Claude probe PAC resolution", .serialized)
struct ClaudeProbePACTests {
    private let target = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    @Test("An inline PAC script that names an HTTP proxy becomes a system-pac route")
    func inlinePACProxy() async {
        let settings: [String: Any] = [
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigJavaScript": """
            function FindProxyForURL(url, host) {
                if (host == "api.anthropic.com") return "PROXY 127.0.0.1:7890; DIRECT";
                return "DIRECT";
            }
            """,
            "ExceptionsList": ["localhost", "*.local"]
        ]
        let variables = await ClaudeProbeNetworkEnvironment.pacProxyVariables(
            systemProxySettings: settings,
            targetURL: target
        )
        #expect(variables?["HTTPS_PROXY"] == "http://127.0.0.1:7890")
        #expect(variables?["http_proxy"] == "http://127.0.0.1:7890")
        #expect(variables?["NO_PROXY"] == "localhost,*.local")

        let candidates = ClaudeProbeNetworkEnvironment.candidates(
            base: [:],
            claudeSettingsEnvironment: [:],
            systemProxySettings: settings,
            pacProxyVariables: variables,
            shellEnvironment: [:]
        )
        #expect(candidates.map(\.source) == ["system-pac", "direct"])
    }

    @Test("SOCKS and DIRECT answers translate correctly")
    func socksAndDirect() async {
        let socks = await ClaudeProbeNetworkEnvironment.pacProxyVariables(
            systemProxySettings: [
                "ProxyAutoConfigEnable": 1,
                "ProxyAutoConfigJavaScript": #"function FindProxyForURL(u, h) { return "SOCKS 127.0.0.1:1080"; }"#
            ],
            targetURL: target
        )
        #expect(socks?["ALL_PROXY"] == "socks5://127.0.0.1:1080")
        #expect(socks?["HTTPS_PROXY"] == nil)

        let direct = await ClaudeProbeNetworkEnvironment.pacProxyVariables(
            systemProxySettings: [
                "ProxyAutoConfigEnable": 1,
                "ProxyAutoConfigJavaScript": #"function FindProxyForURL(u, h) { return "DIRECT"; }"#
            ],
            targetURL: target
        )
        #expect(direct == [:])
    }

    @Test("PAC is ignored when disabled, and a DIRECT answer merges into the direct candidate")
    func disabledAndMerging() async {
        let disabled = await ClaudeProbeNetworkEnvironment.pacProxyVariables(
            systemProxySettings: ["ProxyAutoConfigEnable": 0, "ProxyAutoConfigJavaScript": "x"],
            targetURL: target
        )
        #expect(disabled == nil)

        let candidates = ClaudeProbeNetworkEnvironment.candidates(
            base: [:],
            claudeSettingsEnvironment: [:],
            systemProxySettings: ["ProxyAutoConfigEnable": 1],
            pacProxyVariables: [:],
            shellEnvironment: [:]
        )
        #expect(candidates.map(\.source) == ["direct"])
    }

    @Test("PAC proxy lists prefer the first usable entry")
    func pacListTranslation() {
        let list: [[String: Any]] = [
            [kCFProxyTypeKey as String: kCFProxyTypeFTP as String, kCFProxyHostNameKey as String: "ftp.local"],
            [kCFProxyTypeKey as String: kCFProxyTypeHTTPS as String, kCFProxyHostNameKey as String: "proxy.local", kCFProxyPortNumberKey as String: 3128],
            [kCFProxyTypeKey as String: kCFProxyTypeNone as String]
        ]
        #expect(ClaudeProbeNetworkEnvironment.proxyVariables(fromPACProxies: list)["HTTPS_PROXY"] == "http://proxy.local:3128")
        #expect(ClaudeProbeNetworkEnvironment.proxyVariables(fromPACProxies: [[kCFProxyTypeKey as String: kCFProxyTypeNone as String]]).isEmpty)
        #expect(ClaudeProbeNetworkEnvironment.proxyVariables(fromPACProxies: []).isEmpty)
    }
}

@Suite("Claude network resolution waiting boundaries", .serialized)
struct ClaudeNetworkWaitingTests {
    private let target = URL(string: "https://unused.invalid")!

    @Test("A blocked PAC evaluation times out without accumulating retry workers")
    func blockedPACTimeoutAndRetry() async throws {
        let evaluator = ClaudePACEvaluator()
        let blocked = BlockingPACEvaluation()
        defer { blocked.release() }
        let started = Date()
        let value = await evaluator.variables(script: "fixture", targetURL: target, timeout: 0.05) { _, _ in
            blocked.evaluate()
        }
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(blocked.calls == 1)

        let duringOutstandingWork = await evaluator.variables(script: "fixture", targetURL: target, timeout: 0.05) { _, _ in
            Issue.record("A timed-out native evaluation must not spawn another one")
            return [:]
        }
        #expect(duringOutstandingWork == nil)
        blocked.release()
        // The synchronous worker releases its guard just after returning.
        let deadline = Date().addingTimeInterval(1)
        var retried: [String: String]?
        repeat {
            retried = await evaluator.variables(script: "retry", targetURL: target, timeout: 0.1) { _, _ in [:] }
            if retried == nil { try await Task.sleep(for: .milliseconds(5)) }
        } while retried == nil && Date() < deadline
        #expect(retried == [:])
    }

    @Test("Cancelling PAC evaluation releases the caller and ignores the late value")
    func cancelledPACIgnoresLateResult() async throws {
        let evaluator = ClaudePACEvaluator()
        let blocked = BlockingPACEvaluation()
        defer { blocked.release() }
        let attempt = Task {
            await evaluator.variables(script: "fixture", targetURL: target, timeout: 5) { _, _ in
                blocked.evaluate()
            }
        }
        let deadline = Date().addingTimeInterval(1)
        while blocked.calls == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(blocked.calls == 1)
        let cancelledAt = Date()
        attempt.cancel()
        #expect(await attempt.value == nil)
        #expect(Date().timeIntervalSince(cancelledAt) < 1)
    }

    @Test("A stalled preferred route cannot block a reachable fallback")
    func boundedRouteSelection() async {
        let blocked = BlockingPACEvaluation()
        defer { blocked.release() }
        let start = Date()
        let chosen = await ClaudeProbeNetworkEnvironment.firstReachable([
            .init(source: "stalled", proxyVariables: ["HTTPS_PROXY": "http://127.0.0.1:1"]),
            .init(source: "direct", proxyVariables: [:])
        ], timeout: 0.05) { candidate in
            if candidate.source == "stalled" { _ = blocked.evaluate() }
            return true
        }
        #expect(chosen?.source == "direct")
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test("Already cancelled route selection starts no requests")
    func cancelledRouteSelection() async {
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ClaudeProbeNetworkEnvironment.firstReachable([
                .init(source: "direct", proxyVariables: [:])
            ]) { _ in
                Issue.record("Cancelled selection must not start a request")
                return true
            }
        }
        #expect(await attempt.value == nil)
    }
}

private final class BlockingPACEvaluation: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func evaluate() -> [String: String] {
        lock.lock(); count += 1; lock.unlock()
        // A fail-safe prevents a broken timeout implementation from hanging the suite.
        _ = semaphore.wait(timeout: .now() + 2)
        return ["HTTPS_PROXY": "http://late-fixture.invalid:8080"]
    }

    func release() { semaphore.signal() }
}
