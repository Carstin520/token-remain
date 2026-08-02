import Foundation
import TokenRemainSyncKit

struct DirectSyncPeerRecord: Codable, Identifiable, Equatable {
    let sourceInstanceID: UUID
    let keyID: UUID
    let deviceName: String
    let pairedAt: Date
    var lastSyncAt: Date?

    var id: UUID { sourceInstanceID }
}

@MainActor
final class DirectSyncPeerStore {
    private static let peersKey = "tokenRemain.directSync.peers.v1"
    private static let replayKey = "tokenRemain.directSync.replay.v1"
    private static let keychainService = "com.jamesli.usagedock.direct-sync.peer-key.v1"

    private let defaults: UserDefaults
    private(set) var peers: [DirectSyncPeerRecord]
    private var replayRegistry: SyncReplayRegistry

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        peers = Self.decode([DirectSyncPeerRecord].self, from: defaults.data(forKey: Self.peersKey)) ?? []
        replayRegistry = Self.decode(SyncReplayRegistry.self, from: defaults.data(forKey: Self.replayKey))
            ?? SyncReplayRegistry()
    }

    func record(for sourceInstanceID: UUID) -> DirectSyncPeerRecord? {
        peers.first { $0.sourceInstanceID == sourceInstanceID }
    }

    func key(for peer: DirectSyncPeerRecord) throws -> SyncEncryptionKey {
        let store = keyStore(for: peer.sourceInstanceID)
        guard let encoded = try store.read(),
              let data = Data(base64Encoded: encoded) else {
            throw DirectSyncStoreError.missingKey
        }
        return try SyncEncryptionKey(rawValue: data)
    }

    func upsert(
        sourceInstanceID: UUID,
        keyID: UUID,
        deviceName: String,
        key: SyncEncryptionKey,
        now: Date = Date()
    ) throws {
        guard peers.contains(where: { $0.sourceInstanceID == sourceInstanceID })
                || peers.count < SyncReplayRegistry.maximumSourceCount else {
            throw DirectSyncStoreError.tooManyPeers
        }
        try keyStore(for: sourceInstanceID).save(key.rawValue.base64EncodedString())
        let record = DirectSyncPeerRecord(
            sourceInstanceID: sourceInstanceID,
            keyID: keyID,
            deviceName: deviceName,
            pairedAt: now,
            lastSyncAt: nil
        )
        if let index = peers.firstIndex(where: { $0.sourceInstanceID == sourceInstanceID }) {
            peers[index] = record
            replayRegistry.remove(sourceInstanceID: sourceInstanceID)
        } else {
            peers.append(record)
        }
        try persist()
    }

    func evaluate(_ snapshot: MobileUsageSnapshot) throws -> SyncReplayDecision {
        let decision = try replayRegistry.evaluate(snapshot)
        try persistReplay()
        return decision
    }

    func markSynced(sourceInstanceID: UUID, at date: Date = Date()) throws {
        guard let index = peers.firstIndex(where: { $0.sourceInstanceID == sourceInstanceID }) else { return }
        peers[index].lastSyncAt = date
        try persistPeers()
    }

    func remove(sourceInstanceID: UUID) throws {
        try keyStore(for: sourceInstanceID).delete()
        peers.removeAll { $0.sourceInstanceID == sourceInstanceID }
        replayRegistry.remove(sourceInstanceID: sourceInstanceID)
        try persist()
    }

    private func keyStore(for sourceInstanceID: UUID) -> KeychainSecretStore {
        KeychainSecretStore(
            service: Self.keychainService,
            account: sourceInstanceID.uuidString.lowercased(),
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    private func persist() throws {
        try persistPeers()
        try persistReplay()
    }

    private func persistPeers() throws {
        defaults.set(try JSONEncoder().encode(peers), forKey: Self.peersKey)
    }

    private func persistReplay() throws {
        defaults.set(try JSONEncoder().encode(replayRegistry), forKey: Self.replayKey)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum DirectSyncStoreError: Error {
    case missingKey
    case tooManyPeers
}
