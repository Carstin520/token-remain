import Foundation
import Testing
@testable import UsageDock

@Suite("Kimi Code CLI local credential discovery")
struct KimiLocalCredentialReaderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 造一个假的用户主目录:`<home>/.kimi-code/credentials/kimi-code.json`。
    private func makeHome(
        credentialsJSON: String?,
        deviceID: String? = nil
    ) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "kimi-reader-\(UUID().uuidString)")
        let kimiHome = home.appending(path: ".kimi-code")
        try FileManager.default.createDirectory(
            at: kimiHome.appending(path: "credentials"),
            withIntermediateDirectories: true
        )
        if let credentialsJSON {
            try Data(credentialsJSON.utf8)
                .write(to: kimiHome.appending(path: "credentials/kimi-code.json"))
        }
        if let deviceID {
            try Data(deviceID.utf8).write(to: kimiHome.appending(path: "device_id"))
        }
        return home
    }

    private func reader(home: URL, environment: [String: String] = [:]) -> KimiLocalCredentialReader {
        KimiLocalCredentialReader(homeDirectory: home, environment: environment)
    }

    @Test("Fresh access token loads together with the CLI's device id")
    func freshCredential() throws {
        let expires = now.timeIntervalSince1970 + 3_600
        let home = try makeHome(
            credentialsJSON: #"{"access_token": "tok-live", "refresh_token": "r", "expires_at": \#(expires)}"#,
            deviceID: "device-1\n"
        )
        let credential = reader(home: home).load(now: now)
        #expect(credential == KimiLocalCredential(accessToken: "tok-live", deviceID: "device-1"))
    }

    @Test("Tokens inside the 60s safety margin or already expired are rejected")
    func freshnessMargin() throws {
        let base = now.timeIntervalSince1970
        for offset in [-3_600.0, -1, 0, 30, 59, 60] {
            let home = try makeHome(
                credentialsJSON: #"{"access_token": "t", "expires_at": \#(base + offset)}"#
            )
            #expect(reader(home: home).load(now: now) == nil, "offset \(offset) must be stale")
        }
        let home = try makeHome(
            credentialsJSON: #"{"access_token": "t", "expires_at": \#(base + 61)}"#
        )
        #expect(reader(home: home).load(now: now)?.accessToken == "t")
    }

    @Test("Millisecond and numeric-string expiries are normalized")
    func expiryShapes() {
        let seconds = now.timeIntervalSince1970 + 3_600
        #expect(KimiLocalCredentialReader.expiryDate(seconds * 1000)
            == Date(timeIntervalSince1970: seconds))
        #expect(KimiLocalCredentialReader.expiryDate("\(Int(seconds))")
            == Date(timeIntervalSince1970: seconds))
        #expect(KimiLocalCredentialReader.expiryDate(nil) == nil)
        #expect(KimiLocalCredentialReader.expiryDate("soon") == nil)
        #expect(KimiLocalCredentialReader.expiryDate(0) == nil)
        #expect(KimiLocalCredentialReader.expiryDate(-5) == nil)
    }

    @Test("Missing file, malformed JSON, empty token, or missing expiry all yield nil")
    func malformedInputs() throws {
        let missingFile = try makeHome(credentialsJSON: nil)
        #expect(reader(home: missingFile).load(now: now) == nil)

        let expires = now.timeIntervalSince1970 + 3_600
        for body in [
            "not json",
            #"{"access_token": "", "expires_at": \#(expires)}"#,
            #"{"expires_at": \#(expires)}"#,
            #"{"access_token": "t"}"#,
            #"{"access_token": "t", "expires_at": null}"#
        ] {
            let home = try makeHome(credentialsJSON: body)
            #expect(reader(home: home).load(now: now) == nil, "body \(body) must be rejected")
        }
    }

    @Test("KIMI_CODE_HOME overrides the default ~/.kimi-code location")
    func homeOverride() throws {
        let defaultHome = try makeHome(credentialsJSON: nil)
        let overrideHome = try makeHome(
            credentialsJSON: #"{"access_token": "override-tok", "expires_at": \#(now.timeIntervalSince1970 + 3_600)}"#
        )
        let credential = reader(
            home: defaultHome,
            environment: ["KIMI_CODE_HOME": overrideHome.appending(path: ".kimi-code").path]
        ).load(now: now)
        #expect(credential?.accessToken == "override-tok")
    }

    @Test("An endpoint override env var disables discovery entirely")
    func endpointOverrideBlocksDiscovery() throws {
        let home = try makeHome(
            credentialsJSON: #"{"access_token": "t", "expires_at": \#(now.timeIntervalSince1970 + 3_600)}"#
        )
        for key in KimiLocalCredentialReader.endpointOverrideEnvironmentKeys {
            let credential = reader(home: home, environment: [key: "https://proxy.example.com"])
                .load(now: now)
            #expect(credential == nil, "\(key) must block local discovery")
        }
    }

    @Test("A missing device id is never created on disk")
    func deviceIDIsReadOnly() throws {
        let home = try makeHome(
            credentialsJSON: #"{"access_token": "t", "expires_at": \#(now.timeIntervalSince1970 + 3_600)}"#
        )
        let credential = reader(home: home).load(now: now)
        #expect(credential == KimiLocalCredential(accessToken: "t", deviceID: nil))
        let deviceIDPath = home.appending(path: ".kimi-code/device_id").path
        #expect(!FileManager.default.fileExists(atPath: deviceIDPath))
    }

    @Test("Request contract: official Code API, Bearer auth, CLI platform header")
    func requestContract() {
        #expect(KimiLocalCredentialReader.usageURL.absoluteString
            == "https://api.kimi.com/coding/v1/usages")
        let with = KimiLocalCredentialReader.requestHeaders(
            for: KimiLocalCredential(accessToken: "abc", deviceID: "dev-9")
        )
        #expect(with["Authorization"] == "Bearer abc")
        #expect(with["Accept"] == "application/json")
        #expect(with["X-Msh-Platform"] == "kimi_code_cli")
        #expect(with["X-Msh-Device-Id"] == "dev-9")
        let without = KimiLocalCredentialReader.requestHeaders(
            for: KimiLocalCredential(accessToken: "abc", deviceID: nil)
        )
        #expect(without["X-Msh-Device-Id"] == nil)
    }
}

@Suite("Kimi usage service credential priority")
struct KimiUsageServicePriorityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let validBody = Data(#"""
    {"limits": [{"detail": {"used": 30, "limit": 100},
                 "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}}]}
    """#.utf8)
    /// 形如 JWT 的 CLI access_token:必须仍走 Code API,不能被当作 kimi-auth。
    private static let jwtShapedToken = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSJ9.c2ln"

    private final class HTTPRecorder: @unchecked Sendable {
        var calls: [(url: URL, method: String, headers: [String: String])] = []
        let responder: (URL) throws -> Data
        init(_ responder: @escaping (URL) throws -> Data) { self.responder = responder }
    }

    private func makeService(
        local: KimiLocalCredential?,
        manual: String?,
        recorder: HTTPRecorder
    ) -> KimiUsageService {
        KimiUsageService(
            loadLocalCredential: { _ in local },
            loadManualSecret: { manual },
            httpRequest: { url, method, headers, _ in
                recorder.calls.append((url, method, headers))
                return try recorder.responder(url)
            }
        )
    }

    @Test("A routed secret wins and skips local discovery")
    func routedSecretFirst() async throws {
        let recorder = HTTPRecorder { _ in Self.validBody }
        let service = KimiUsageService(
            loadLocalCredential: { _ in
                Issue.record("local discovery must not run for a routed secret")
                return nil
            },
            loadManualSecret: { nil },
            httpRequest: { url, method, headers, _ in
                recorder.calls.append((url, method, headers))
                return try recorder.responder(url)
            }
        )
        _ = try await service.fetch(secret: "sk-routed", now: now)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].url.absoluteString == "https://api.kimi.com/coding/v1/usages")
        #expect(recorder.calls[0].headers["Authorization"] == "Bearer sk-routed")
    }

    @Test("A fresh CLI token goes to the Code API even when it looks like a JWT")
    func localTokenKeepsCodeAPIContract() async throws {
        let recorder = HTTPRecorder { _ in Self.validBody }
        let service = makeService(
            local: KimiLocalCredential(accessToken: Self.jwtShapedToken, deviceID: "dev"),
            manual: "manual-secret",
            recorder: recorder
        )
        let quota = try await service.fetch(now: now)
        #expect(quota.provider == .kimi)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].url.absoluteString == "https://api.kimi.com/coding/v1/usages")
        #expect(recorder.calls[0].method == "GET")
        #expect(recorder.calls[0].headers["Authorization"] == "Bearer \(Self.jwtShapedToken)")
        #expect(recorder.calls[0].headers["Cookie"] == nil)
    }

    @Test("A rejected CLI token falls back to the manual keychain secret")
    func localRejectionFallsBackToManual() async throws {
        let recorder = HTTPRecorder { url in
            if url.host() == "api.kimi.com" {
                throw ExtendedProviderError.secretRejected(.kimi, 401)
            }
            return Self.validBody
        }
        let service = makeService(
            local: KimiLocalCredential(accessToken: "stale-but-looked-fresh", deviceID: nil),
            manual: Self.jwtShapedToken,
            recorder: recorder
        )
        let quota = try await service.fetch(now: now)
        #expect(quota.provider == .kimi)
        #expect(recorder.calls.count == 2)
        // 手动 JWT 走 kimi-auth 网页端口径。
        #expect(recorder.calls[1].url.host() == "www.kimi.com")
        #expect(recorder.calls[1].headers["Cookie"] == "kimi-auth=\(Self.jwtShapedToken)")
    }

    @Test("A rejected CLI token with no manual fallback surfaces the rejection")
    func localRejectionWithoutManual() async throws {
        let recorder = HTTPRecorder { _ in
            throw ExtendedProviderError.secretRejected(.kimi, 401)
        }
        let service = makeService(
            local: KimiLocalCredential(accessToken: "t", deviceID: nil),
            manual: nil,
            recorder: recorder
        )
        await #expect(throws: ExtendedProviderError.self) {
            _ = try await service.fetch(now: now)
        }
    }

    @Test("No local credential falls back to the existing manual flow")
    func manualFallback() async throws {
        let recorder = HTTPRecorder { _ in Self.validBody }
        let service = makeService(local: nil, manual: "sk-manual", recorder: recorder)
        _ = try await service.fetch(now: now)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].headers["Authorization"] == "Bearer sk-manual")
    }

    @Test("Nothing configured surfaces notConfigured without any request")
    func nothingConfigured() async {
        let recorder = HTTPRecorder { _ in Self.validBody }
        let service = makeService(local: nil, manual: nil, recorder: recorder)
        await #expect(throws: ExtendedProviderError.self) {
            _ = try await service.fetch(now: now)
        }
        #expect(recorder.calls.isEmpty)
    }
}
