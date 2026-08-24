import Foundation
import Network
import Testing
@testable import UsageDock

@Suite("Direct sync HTTP server")
struct DirectSyncHTTPServerTests {
    @Test("Listener accepts one bounded HTTP request and closes the connection")
    func requestRoundTrip() async throws {
        let server = DirectSyncHTTPServer()
        let readiness = ListenerReadiness()
        try server.start(
            port: 47_932,
            handler: { request in
                .json(Data("{\"path\":\"\(request.path)\",\"bytes\":\(request.body.count)}".utf8))
            },
            stateChanged: { state in
                switch state {
                case .ready: readiness.finish(true)
                case .failed: readiness.finish(false)
                default: break
                }
            }
        )
        let ready = await readiness.value()
        #expect(ready)
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:47932/v1/test")!)
        request.httpMethod = "POST"
        request.httpBody = Data("abc".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "{\"path\":\"/v1/test\",\"bytes\":3}")
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }
}

private final class ListenerReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
