import Combine
import Foundation
import Network
import TokenRemainSyncKit

@MainActor
final class DirectSyncController: ObservableObject {
    enum State: Equatable {
        case starting
        case listening
        case failed(String)
    }

    static let shared = DirectSyncController()
    static let pairingLifetime: TimeInterval = 10 * 60

    @Published private(set) var state: State = .starting
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: Date?
    @Published private(set) var peers: [DirectSyncPeerRecord] = []

    let address: String

    private weak var usageStore: UsageStore?
    private let defaults: UserDefaults
    private let peerStore: DirectSyncPeerStore
    private let server = DirectSyncHTTPServer()
    private var sourceInstanceID: UUID?
    private var pairingSecret: Data?
    private var pairingExpiryTask: Task<Void, Never>?
    private var started = false
    private let sequenceKey = "tokenRemain.directSync.sequence.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        peerStore = DirectSyncPeerStore(defaults: defaults)
        peers = peerStore.peers
        let host = ProcessInfo.processInfo.hostName
        address = "http://\(host):\(DirectSyncConstants.defaultPort)"
    }

    func attach(to store: UsageStore) {
        usageStore = store
        guard !started else { return }
        started = true
        do {
            sourceInstanceID = try SourceIdentityStore(defaults: defaults).loadOrCreate()
            try server.start(
                handler: { [weak self] request in
                    guard let self else { return .text("Server unavailable", status: 503) }
                    return await self.route(request)
                },
                stateChanged: { [weak self] state in
                    Task { @MainActor [weak self] in self?.applyListenerState(state) }
                }
            )
        } catch {
            state = .failed(Self.safeMessage(error))
        }
    }

    func beginPairing(now: Date = Date()) {
        guard state == .listening else { return }
        let secret = DirectSyncPairing.randomSecret()
        pairingSecret = secret
        pairingCode = try? DirectSyncPairing.displayCode(for: secret)
        pairingExpiresAt = now.addingTimeInterval(Self.pairingLifetime)
        pairingExpiryTask?.cancel()
        pairingExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingLifetime))
            guard !Task.isCancelled, self?.pairingSecret == secret else { return }
            self?.cancelPairing()
        }
    }

    func cancelPairing() {
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSecret = nil
        pairingCode = nil
        pairingExpiresAt = nil
    }

    func removePeer(_ sourceInstanceID: UUID) {
        try? peerStore.remove(sourceInstanceID: sourceInstanceID)
        peers = peerStore.peers
    }

    private func route(_ request: DirectSyncHTTPRequest) -> DirectSyncHTTPResponse {
        guard request.method == "POST" else { return .text("Not found", status: 404) }
        switch request.path {
        case "/v1/pair": return handlePair(request.body)
        case "/v1/snapshot": return handleSnapshot(request.body)
        default: return .text("Not found", status: 404)
        }
    }

    private func handlePair(_ body: Data, now: Date = Date()) -> DirectSyncHTTPResponse {
        guard let secret = pairingSecret,
              let expiry = pairingExpiresAt,
              expiry >= now,
              let sourceInstanceID else {
            cancelPairing()
            return .text("No active pairing session", status: 429)
        }
        do {
            let request = try JSONDecoder().decode(DirectSyncPairingRequest.self, from: body)
            let accepted = try DirectSyncPairing.accept(
                request: request,
                secret: secret,
                serverSourceInstanceID: sourceInstanceID,
                serverDeviceName: Host.current().localizedName ?? "Mac"
            )
            try peerStore.upsert(
                sourceInstanceID: request.sourceInstanceID,
                keyID: accepted.response.keyID,
                deviceName: request.deviceName,
                key: accepted.key,
                now: now
            )
            peers = peerStore.peers
            cancelPairing()
            return .json(try JSONEncoder().encode(accepted.response))
        } catch DirectSyncPairingError.invalidProof {
            return .text("Pairing proof rejected", status: 401)
        } catch {
            return .text("Pairing request rejected", status: 400)
        }
    }

    private func handleSnapshot(_ body: Data, now: Date = Date()) -> DirectSyncHTTPResponse {
        guard let usageStore, let sourceInstanceID else {
            return .text("Server unavailable", status: 503)
        }
        do {
            let envelope = try EncryptedSyncEnvelope.decoded(from: body)
            guard let peer = peerStore.record(for: envelope.sourceInstanceID),
                  peer.keyID == envelope.keyID else {
                return .text("Unknown device", status: 401)
            }
            let key = try peerStore.key(for: peer)
            let snapshot = try envelope.open(
                using: key,
                containerID: DirectSyncConstants.envelopeContext,
                supportedProviderIDs: SyncedProviderID.supportedOnCurrentMobile,
                configuration: .current(now: now)
            )
            switch try peerStore.evaluate(snapshot) {
            case .accepted:
                usageStore.applyDirectSyncSnapshot(snapshot)
            case .duplicate:
                break
            case .replayedOlderSequence, .conflictingSequence:
                return .text("Snapshot replay rejected", status: 409)
            }
            try peerStore.markSynced(sourceInstanceID: peer.sourceInstanceID, at: now)
            peers = peerStore.peers

            let responseSnapshot = MobileSnapshotRedactor.makeSnapshot(
                from: usageStore.localQuotasForDirectSync,
                sourceInstanceID: sourceInstanceID,
                sequence: nextSequence(),
                generatedAt: now
            )
            let responseEnvelope = try EncryptedSyncEnvelope.seal(
                responseSnapshot,
                using: key,
                keyID: peer.keyID,
                containerID: DirectSyncConstants.envelopeContext,
                configuration: .current(now: now)
            )
            return .json(try responseEnvelope.encoded())
        } catch {
            return .text("Encrypted snapshot rejected", status: 400)
        }
    }

    private func nextSequence() -> UInt64 {
        let current = UInt64(max(0, defaults.integer(forKey: sequenceKey)))
        let next = current == UInt64.max ? UInt64.max : current + 1
        defaults.set(Int(clamping: next), forKey: sequenceKey)
        return max(1, next)
    }

    private func applyListenerState(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            state = .listening
        case .failed(let error):
            state = .failed(Self.safeMessage(error))
        case .cancelled:
            state = .failed("Direct sync stopped")
        default:
            state = .starting
        }
    }

    private static func safeMessage(_ error: Error) -> String {
        String(describing: error)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(160)
            .description
    }
}
