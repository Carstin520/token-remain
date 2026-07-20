import Foundation
import TokenRemainKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// iPhone → Watch boundary.
///
/// `updateApplicationContext` only: the watch needs latest-value semantics, not a
/// queue, so context overwrites are exactly right. No `sendMessage`, no reply
/// handlers, no background transfers — and nothing ever flows watch → phone.
final class WatchSyncEngine: NSObject, @unchecked Sendable {
    struct Status: Equatable, Sendable {
        var isSupported = false
        var isPaired = false
        var isWatchAppInstalled = false
        var lastPushedAt: Date?
    }

    private let lock = NSLock()
    private var _status = Status()

    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    private func mutate(_ body: (inout Status) -> Void) {
        lock.lock()
        body(&_status)
        lock.unlock()
    }

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        mutate { $0.isSupported = true }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    func push(_ snapshot: UsageSnapshot) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, let data = try? snapshot.encoded() else { return }
        do {
            try session.updateApplicationContext(["snapshot": data])
            mutate { $0.lastPushedAt = Date() }
        } catch {
            // A failed context update is not worth surfacing as an error state:
            // the next successful push overwrites it wholesale.
        }
        refreshReachability()
        #endif
    }

    private func refreshReachability() {
        #if canImport(WatchConnectivity) && os(iOS)
        let session = WCSession.default
        mutate {
            $0.isPaired = session.isPaired
            $0.isWatchAppInstalled = session.isWatchAppInstalled
        }
        #endif
    }
}

#if canImport(WatchConnectivity)
extension WatchSyncEngine: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        refreshReachability()
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        refreshReachability()
    }
    #endif
}
#endif
