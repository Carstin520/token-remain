import Foundation
import Observation
import TokenRemainKit
import WatchConnectivity

/// Watch side of the boundary. Decodes the `applicationContext` the iPhone pushed,
/// persists it to the watch's own App Group container, and reloads complications.
///
/// The watch **never** composes, projects or mutates data — it renders the last
/// snapshot it was given, plus staleness.
@Observable
@MainActor
final class WatchSnapshotReceiver: NSObject, @unchecked Sendable {
    private(set) var snapshot: UsageSnapshot
    private(set) var receivedAt: Date?

    private let store = SnapshotStore.shared

    override init() {
        snapshot = SnapshotStore.shared.readOrEmpty(now: Date())
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // A context received while the app was not running is still available.
        apply(payload: session.receivedApplicationContext["snapshot"] as? Data)
    }

    private func apply(payload: Data?) {
        guard let payload, let decoded = UsageSnapshot.decoded(from: payload) else { return }
        snapshot = decoded
        receivedAt = Date()
        store.write(decoded)
        WidgetReload.all()
    }

    /// The context dictionary is not `Sendable`; lift the payload out on the
    /// calling thread and hand only `Data` across to the main actor.
    nonisolated func ingest(_ context: [String: Any]) {
        let payload = context["snapshot"] as? Data
        Task { @MainActor in self.apply(payload: payload) }
    }
}

extension WatchSnapshotReceiver: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        ingest(session.receivedApplicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingest(applicationContext)
    }
}
