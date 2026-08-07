import Darwin
import Foundation
import Testing
@testable import UsageDock

@Suite("Qoder local IPC discovery + cookie fallback")
struct QoderUsageServiceTests {
    // MARK: 辅助

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "qoder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeInfoFile(home: URL, appDir: String, contents: String) throws {
        let dir = home.appending(path: "Library/Application Support/\(appDir)/SharedClientCache")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: dir.appending(path: ".info.json"))
    }

    private func frame(_ json: String) -> Data {
        var data = Data("Content-Length: \(json.utf8.count)\r\n\r\n".utf8)
        data.append(Data(json.utf8))
        return data
    }

    private func makeService(
        home: URL,
        environment: [String: String] = [:],
        ipc: @escaping (String, Data) throws -> Data = { _, _ in
            throw QoderIPCError.socketUnavailable
        },
        cookie: String? = nil,
        http: @escaping (URL, [String: String]) async throws -> Data = { _, _ in
            throw ExtendedProviderError.requestFailed(.qoder, 500)
        }
    ) -> QoderUsageService {
        var service = QoderUsageService()
        service.home = home
        service.environment = environment
        service.ipcExchange = ipc
        service.loadCookie = { cookie }
        service.httpRequest = http
        return service
    }

    private final class Box: @unchecked Sendable {
        var cookieAsked = false
        var httpURLs: [URL] = []
        var httpHeaders: [[String: String]] = []
        var ipcSocketPaths: [String] = []
        var ipcRequests: [Data] = []
    }

    private static let rpcResultJSON = """
    {"jsonrpc": "2.0", "id": 1, "result": {
        "userType": "personal_standard",
        "isQuotaExceeded": false,
        "totalUsagePercentage": 25,
        "expiresAt": 1798761600000,
        "userQuota": {"used": 25, "total": 100, "remaining": 75, "percentage": 25}
    }}
    """

    private static let httpUsageJSON = """
    {"totalQuota": {"quotaSummary": {"usedValue": 40, "limitValue": 100}}}
    """

    // MARK: 发现

    @Test("Discovery reads ipcServerPath from Qoder and QoderCN .info.json")
    func discovery() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeInfoFile(home: home, appDir: "Qoder", contents: #"{"ipcServerPath": "/tmp/qoder-intl.sock"}"#)
        try writeInfoFile(home: home, appDir: "QoderCN", contents: #"{"ipcServerPath": " /tmp/qoder-cn.sock "}"#)
        let editions = QoderLocalIPC.editions
        #expect(editions.map(\.appDir) == ["Qoder", "QoderCN"])
        #expect(QoderLocalIPC.socketPath(edition: editions[0], home: home, environment: [:])
            == "/tmp/qoder-intl.sock")
        #expect(QoderLocalIPC.socketPath(edition: editions[1], home: home, environment: [:])
            == "/tmp/qoder-cn.sock")
    }

    @Test("Discovery returns nil for missing, malformed, or endpoint-less info files")
    func discoveryDegenerate() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let intl = QoderLocalIPC.editions[0]
        #expect(QoderLocalIPC.socketPath(edition: intl, home: home, environment: [:]) == nil)
        try writeInfoFile(home: home, appDir: "Qoder", contents: "not json {")
        #expect(QoderLocalIPC.socketPath(edition: intl, home: home, environment: [:]) == nil)
        try writeInfoFile(home: home, appDir: "Qoder", contents: #"{"ipcServerPath": "  "}"#)
        #expect(QoderLocalIPC.socketPath(edition: intl, home: home, environment: [:]) == nil)
        try writeInfoFile(home: home, appDir: "Qoder", contents: #"{"pid": 42}"#)
        #expect(QoderLocalIPC.socketPath(edition: intl, home: home, environment: [:]) == nil)
    }

    @Test("QODER_HOME overrides the default data root")
    func discoveryEnvOverride() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appending(path: "custom-root")
        let dir = custom.appending(path: "SharedClientCache")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"ipcServerPath": "/tmp/custom.sock"}"#.utf8)
            .write(to: dir.appending(path: ".info.json"))
        let path = QoderLocalIPC.socketPath(
            edition: QoderLocalIPC.editions[0],
            home: home,
            environment: ["QODER_HOME": custom.path]
        )
        #expect(path == "/tmp/custom.sock")
    }

    // MARK: 帧编解码

    @Test("Request frame carries a Content-Length header and a JSON-RPC body")
    func encodeRequest() throws {
        let data = QoderLocalIPC.encodeRequest(method: "credit/usage")
        let separator = Data("\r\n\r\n".utf8)
        let headerEnd = try #require(data.range(of: separator))
        let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let body = data[headerEnd.upperBound...]
        #expect(header == "Content-Length: \(body.count)")
        let message = try #require(ExtendedHTTP.json(Data(body)))
        #expect(message["jsonrpc"] as? String == "2.0")
        #expect(message["method"] as? String == "credit/usage")
        #expect(message["id"] as? Int == 1)
        #expect((message["params"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Frame parser waits for a full frame and rejects broken headers")
    func frameParsing() throws {
        let full = frame(#"{"ok": true}"#)
        #expect(try QoderLocalIPC.frameBody(in: full) == Data(#"{"ok": true}"#.utf8))
        // 头部还没收全 / 体还没收全 → nil,继续等。
        #expect(try QoderLocalIPC.frameBody(in: Data("Content-Length: 12\r\n".utf8)) == nil)
        #expect(try QoderLocalIPC.frameBody(in: full.prefix(full.count - 3)) == nil)
        // 帧后多余字节不影响取当前帧。
        var padded = full
        padded.append(Data("garbage".utf8))
        #expect(try QoderLocalIPC.frameBody(in: padded) == Data(#"{"ok": true}"#.utf8))
        #expect(throws: QoderIPCError.self) {
            try QoderLocalIPC.frameBody(in: Data("X-Nope: 1\r\n\r\n{}".utf8))
        }
        #expect(throws: QoderIPCError.self) {
            try QoderLocalIPC.frameBody(in: Data("Content-Length: 999999999\r\n\r\n".utf8))
        }
    }

    @Test("RPC envelope parsing surfaces results and rejects errors")
    func rpcEnvelope() throws {
        let result = try QoderLocalIPC.rpcResult(
            fromFrameBody: Data(Self.rpcResultJSON.utf8)
        )
        #expect((result["userQuota"] as? [String: Any]) != nil)
        #expect(throws: QoderIPCError.self) {
            try QoderLocalIPC.rpcResult(fromFrameBody: Data("not json".utf8))
        }
        #expect(throws: QoderIPCError.self) {
            try QoderLocalIPC.rpcResult(
                fromFrameBody: Data(#"{"jsonrpc":"2.0","id":1,"error":{"message":"nope"}}"#.utf8)
            )
        }
        #expect(throws: QoderIPCError.self) {
            try QoderLocalIPC.rpcResult(fromFrameBody: Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        }
    }

    // MARK: 本地 IPC 结果解析

    @Test("RPC quota maps used/total/remaining, plan, and expiry")
    func rpcQuota() throws {
        let result = try QoderLocalIPC.rpcResult(fromFrameBody: Data(Self.rpcResultJSON.utf8))
        let quota = try QoderUsageService.parseRPCQuota(result)
        #expect(quota.provider == .qoder)
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.planName == "personal_standard")
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_798_761_600))
    }

    @Test("RPC quota renders an empty 0/0 plan as 0%, not 100%")
    func rpcZeroTotal() throws {
        let result: [String: Any] = [
            "isQuotaExceeded": true,
            "userQuota": ["used": 0, "total": 0, "remaining": 0]
        ]
        let quota = try QoderUsageService.parseRPCQuota(result)
        #expect(quota.primary.usedPercent == 0)
    }

    @Test("RPC quota pins an exceeded account at 100%")
    func rpcExceeded() throws {
        let result: [String: Any] = [
            "isQuotaExceeded": true,
            "totalUsagePercentage": 37,
            "userQuota": ["used": 37, "total": 100, "remaining": 63]
        ]
        let quota = try QoderUsageService.parseRPCQuota(result)
        #expect(quota.primary.usedPercent == 100)
    }

    @Test("RPC quota computes the percent when none is reported")
    func rpcComputedPercent() throws {
        let result: [String: Any] = ["userQuota": ["used": 30, "total": 120, "remaining": 90]]
        let quota = try QoderUsageService.parseRPCQuota(result)
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.planName == nil)
        #expect(quota.primary.resetsAt == nil)
    }

    @Test("Far-future no-expiry sentinel and epoch variants normalize correctly")
    func rpcExpiry() throws {
        // Qoder 免费账号的 9999-12-31 哨兵(毫秒)→ 无重置日。
        #expect(QoderUsageService.expiryDate(253_402_214_400_000) == nil)
        #expect(QoderUsageService.expiryDate(1_798_761_600_000)
            == Date(timeIntervalSince1970: 1_798_761_600))
        #expect(QoderUsageService.expiryDate(1_798_761_600)
            == Date(timeIntervalSince1970: 1_798_761_600))
        #expect(QoderUsageService.expiryDate("2026-12-31T00:00:00Z")
            == Date(timeIntervalSince1970: 1_798_675_200))
        #expect(QoderUsageService.expiryDate("9999-12-31T23:59:59Z") == nil)
        #expect(QoderUsageService.expiryDate(nil) == nil)
        #expect(QoderUsageService.expiryDate("soon") == nil)
    }

    @Test("Malformed RPC results are rejected")
    func rpcMalformed() {
        #expect(throws: ExtendedProviderError.self) {
            try QoderUsageService.parseRPCQuota([:])
        }
        #expect(throws: ExtendedProviderError.self) {
            try QoderUsageService.parseRPCQuota(["userQuota": ["used": 5]])
        }
        #expect(throws: ExtendedProviderError.self) {
            try QoderUsageService.parseRPCQuota(
                ["userQuota": ["used": -1, "total": 100, "remaining": 101]]
            )
        }
    }

    // MARK: 手动 Cookie:请求头与站点隔离

    @Test("Browser-compatible headers target each site's own origin")
    func requestHeaders() {
        for site in QoderSite.allCases {
            let headers = QoderUsageService.requestHeaders(cookie: "session=abc", site: site)
            #expect(headers["Cookie"] == "session=abc")
            #expect(headers["Accept"] == "application/json, text/plain, */*")
            #expect(headers["Accept-Language"] == "en-US,en;q=0.9")
            #expect(headers["User-Agent"]?.contains("Chrome/143") == true)
            #expect(headers["Origin"] == site.origin)
            #expect(headers["Referer"] == "\(site.origin)/account/usage")
            #expect(headers["X-Requested-With"] == "XMLHttpRequest")
            #expect(headers["Bx-V"] == "2.5.35")
        }
        #expect(QoderSite.international.usageURL.host() == "qoder.com")
        #expect(QoderSite.china.usageURL.host() == "qoder.com.cn")
        #expect(QoderSite.international.origin == "https://qoder.com")
        #expect(QoderSite.china.origin == "https://qoder.com.cn")
    }

    @Test("Plain cookie headers normalize and default to the international site")
    func cookiePlain() throws {
        let credentials = try #require(QoderUsageService.cookieCredentials("  a=1;  b=2 ;bad; =x "))
        #expect(credentials.cookie == "a=1; b=2")
        #expect(credentials.site == .international)

        let prefixed = try #require(QoderUsageService.cookieCredentials("Cookie: session=v; t=1"))
        #expect(prefixed.cookie == "session=v; t=1")
    }

    @Test("curl captures extract the cookie header and pin the site from the URL")
    func cookieCurlCapture() throws {
        let intl = """
        curl 'https://qoder.com/api/v2/me/usages/big_model_credits' \\
          -H 'accept: application/json, text/plain, */*' \\
          -H 'cookie: sid=abc; token=def' \\
          -H 'user-agent: Mozilla/5.0'
        """
        let intlCredentials = try #require(QoderUsageService.cookieCredentials(intl))
        #expect(intlCredentials.cookie == "sid=abc; token=def")
        #expect(intlCredentials.site == .international)

        let china = """
        curl 'https://qoder.com.cn/api/v2/me/usages/big_model_credits' \\
          -H 'cookie: cn_sid=xyz'
        """
        let chinaCredentials = try #require(QoderUsageService.cookieCredentials(china))
        #expect(chinaCredentials.cookie == "cn_sid=xyz")
        #expect(chinaCredentials.site == .china)
        #expect(chinaCredentials.site.usageURL.host() == "qoder.com.cn")

        let flagged = try #require(
            QoderUsageService.cookieCredentials(#"curl https://qoder.com/x -b 'sid=abc; b=2'"#)
        )
        #expect(flagged.cookie == "sid=abc; b=2")
    }

    @Test("QODER_SITE routes an unpinned cookie; captures with a URL win over it")
    func cookieSiteEnv() throws {
        let cn = try #require(
            QoderUsageService.cookieCredentials("sid=abc", environment: ["QODER_SITE": "cn"])
        )
        #expect(cn.site == .china)
        let intl = try #require(
            QoderUsageService.cookieCredentials(
                "curl 'https://qoder.com/x' -H 'cookie: sid=abc'",
                environment: ["QODER_SITE": "cn"]
            )
        )
        #expect(intl.site == .international)
        #expect(QoderUsageService.cookieCredentials("", environment: [:]) == nil)
    }

    @Test("A domain inside a plain cookie value cannot redirect the credential")
    func cookieValueCannotSelectSite() throws {
        let plain = try #require(
            QoderUsageService.cookieCredentials(
                "sid=international; redirect=https://qoder.com.cn/account/usage",
                environment: [:]
            )
        )
        #expect(plain.site == .international)

        let envPinned = try #require(
            QoderUsageService.cookieCredentials(
                "sid=china; redirect=https://qoder.com/account/usage",
                environment: ["QODER_SITE": "cn"]
            )
        )
        #expect(envPinned.site == .china)

        let curlHeaderFirst = try #require(
            QoderUsageService.cookieCredentials(
                "curl -H 'cookie: sid=international; redirect=https://qoder.com.cn/x' " +
                    "'https://qoder.com/api/v2/me/usages/big_model_credits'",
                environment: [:]
            )
        )
        #expect(curlHeaderFirst.site == .international)
    }

    // MARK: 取数顺序

    @Test("Local IPC wins without consulting the stored cookie")
    func fetchPrefersLocalIPC() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeInfoFile(home: home, appDir: "Qoder", contents: #"{"ipcServerPath": "/tmp/qoder-live.sock"}"#)
        let box = Box()
        // ipcExchange 的契约:收整帧请求,返回解帧后的响应体。
        let responseBody = Data(Self.rpcResultJSON.utf8)
        var service = makeService(home: home, ipc: { path, request in
            box.ipcSocketPaths.append(path)
            box.ipcRequests.append(request)
            return responseBody
        })
        service.loadCookie = {
            box.cookieAsked = true
            return "sid=should-not-be-used"
        }
        service.httpRequest = { url, _ in
            box.httpURLs.append(url)
            throw ExtendedProviderError.requestFailed(.qoder, 500)
        }
        let quota = try await service.fetch()
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.planName == "personal_standard")
        #expect(box.ipcSocketPaths == ["/tmp/qoder-live.sock"])
        #expect(box.cookieAsked == false)
        #expect(box.httpURLs.isEmpty)
        // 发出的确实是一帧 credit/usage 请求。
        let sentFrame = try #require(box.ipcRequests.first)
        let requestBody = try #require(try QoderLocalIPC.frameBody(in: sentFrame))
        #expect(ExtendedHTTP.json(requestBody)?["method"] as? String == "credit/usage")
    }

    @Test("A stopped Qoder app falls through to the manual cookie")
    func fetchFallsBackWhenSocketDead() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeInfoFile(home: home, appDir: "Qoder", contents: #"{"ipcServerPath": "/tmp/qoder-dead.sock"}"#)
        let box = Box()
        let service = makeService(
            home: home,
            ipc: { _, _ in throw QoderIPCError.socketUnavailable },
            cookie: "sid=abc",
            http: { url, headers in
                box.httpURLs.append(url)
                box.httpHeaders.append(headers)
                return Data(Self.httpUsageJSON.utf8)
            }
        )
        let quota = try await service.fetch()
        #expect(quota.primary.usedPercent == 40)
        #expect(box.httpURLs == [QoderSite.international.usageURL])
        #expect(box.httpHeaders.first?["Cookie"] == "sid=abc")
        #expect(box.httpHeaders.first?["Bx-V"] == "2.5.35")
    }

    @Test("A malformed IPC response also falls through to the manual cookie")
    func fetchFallsBackOnMalformedIPC() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeInfoFile(home: home, appDir: "Qoder", contents: #"{"ipcServerPath": "/tmp/qoder-odd.sock"}"#)
        let box = Box()
        let badBody = Data(#"{"jsonrpc":"2.0","id":1,"result":{"unexpected":true}}"#.utf8)
        let service = makeService(
            home: home,
            ipc: { _, _ in badBody },
            cookie: "sid=abc",
            http: { url, _ in
                box.httpURLs.append(url)
                return Data(Self.httpUsageJSON.utf8)
            }
        )
        let quota = try await service.fetch()
        #expect(quota.primary.usedPercent == 40)
        #expect(box.httpURLs.count == 1)
    }

    @Test("A CN cookie is only ever sent to qoder.com.cn")
    func fetchRoutesChinaCookie() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let box = Box()
        let service = makeService(
            home: home,
            cookie: "curl 'https://qoder.com.cn/api/v2/me/usages/big_model_credits' -H 'cookie: cn_sid=xyz'",
            http: { url, headers in
                box.httpURLs.append(url)
                box.httpHeaders.append(headers)
                return Data(Self.httpUsageJSON.utf8)
            }
        )
        _ = try await service.fetch()
        #expect(box.httpURLs.map { $0.host() } == ["qoder.com.cn"])
        #expect(box.httpHeaders.first?["Origin"] == "https://qoder.com.cn")
        #expect(box.httpHeaders.first?["Referer"] == "https://qoder.com.cn/account/usage")
        #expect(box.httpHeaders.first?["Cookie"] == "cn_sid=xyz")
    }

    @Test("Neither local IPC nor cookie configured surfaces notConfigured")
    func fetchNotConfigured() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = makeService(home: home)
        do {
            _ = try await service.fetch()
            Issue.record("expected notConfigured")
        } catch let error as ExtendedProviderError {
            guard case .notConfigured(.qoder) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test("HTTP zero-credit and malformed payloads are rejected")
    func httpMalformed() {
        #expect(throws: ExtendedProviderError.self) {
            try QoderUsageService.parse(Data("not json".utf8))
        }
        #expect(throws: ExtendedProviderError.self) {
            try QoderUsageService.parse(
                Data(#"{"totalQuota": {"quotaSummary": {"usedValue": 0, "limitValue": 0}}}"#.utf8)
            )
        }
        #expect(throws: ExtendedProviderError.self) {
            try QoderUsageService.parse(
                Data(#"{"totalQuota": {"quotaSummary": {"usedValue": -1, "limitValue": 100}}}"#.utf8)
            )
        }
    }

    // MARK: 真 socket 往返

    @Test("IPC exchange completes a framed round trip over a real Unix socket")
    func socketRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "qoder-\(UUID().uuidString.prefix(8)).sock").path
        let server = try QoderTestSocketServer(
            path: path,
            responseFrame: frame(Self.rpcResultJSON)
        )
        defer { server.stop() }
        let body = try QoderLocalIPC.exchange(
            socketPath: path,
            request: QoderLocalIPC.encodeRequest(method: "credit/usage"),
            timeout: 5
        )
        let result = try QoderLocalIPC.rpcResult(fromFrameBody: body)
        let quota = try QoderUsageService.parseRPCQuota(result)
        #expect(quota.primary.usedPercent == 25)
        let received = try #require(ExtendedHTTP.json(server.capturedRequest))
        #expect(received["method"] as? String == "credit/usage")
    }

    @Test("Full fetch discovers the socket from .info.json and uses the live probe")
    func socketEndToEnd() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = FileManager.default.temporaryDirectory
            .appending(path: "qoder-\(UUID().uuidString.prefix(8)).sock").path
        let server = try QoderTestSocketServer(
            path: path,
            responseFrame: frame(Self.rpcResultJSON)
        )
        defer { server.stop() }
        try writeInfoFile(
            home: home,
            appDir: "Qoder",
            contents: #"{"ipcServerPath": "\#(path)"}"#
        )
        var service = QoderUsageService()
        service.home = home
        service.environment = [:]
        service.loadCookie = { nil }
        service.httpRequest = { _, _ in throw ExtendedProviderError.requestFailed(.qoder, 500) }
        let quota = try await service.fetch()
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.planName == "personal_standard")
    }

    @Test("Exchange fails fast when nothing listens on the socket")
    func socketUnavailable() {
        #expect(throws: QoderIPCError.self) {
            try QoderLocalIPC.exchange(
                socketPath: "/tmp/qoder-\(UUID().uuidString).sock",
                request: QoderLocalIPC.encodeRequest(method: "credit/usage"),
                timeout: 1
            )
        }
    }
}

/// 测试用最小 Unix-socket 服务器:收满一帧请求后回写固定响应。
private final class QoderTestSocketServer: @unchecked Sendable {
    private let listenFD: Int32
    private let path: String
    private let lock = NSLock()
    private var request = Data()

    var capturedRequest: Data {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    init(path: String, responseFrame: Data) throws {
        self.path = path
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(listenFD)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 2) == 0 else {
            close(listenFD)
            throw POSIXError(.EIO)
        }
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4_096)
                while true {
                    if let body = (try? QoderLocalIPC.frameBody(in: buffer)) ?? nil {
                        self?.store(body)
                        break
                    }
                    let count = read(client, &chunk, chunk.count)
                    guard count > 0 else {
                        close(client)
                        return
                    }
                    buffer.append(contentsOf: chunk[0..<count])
                }
                responseFrame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    var sent = 0
                    while sent < raw.count {
                        let written = write(client, base + sent, raw.count - sent)
                        guard written > 0 else { return }
                        sent += written
                    }
                }
                close(client)
            }
        }
    }

    private func store(_ body: Data) {
        lock.lock()
        request = body
        lock.unlock()
    }

    func stop() {
        close(listenFD)
        unlink(path)
    }
}
