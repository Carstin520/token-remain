#if TOKENREMAIN_CLOUD_SYNC
import Combine
import CryptoKit
import Foundation
import OSLog
import Security
import TokenRemainSyncKit

@MainActor
final class CrossDeviceSyncController: ObservableObject {
    struct PreviewProvider: Identifiable, Equatable {
        struct Window: Equatable {
            let usedPercent: Double
            let windowMinutes: Int
            let resetsAt: Date?
        }

        let id: String
        let windows: [Window]
        let capturedAt: Date
    }

    enum State: Equatable {
        case off
        case needsSignedCapabilities
        case waitingForMacData
        case checkingICloud
        case anotherMacIsPrimary
        case uploading
        case synced(Date)
        case failed(Failure)
    }

    enum Failure: String, Equatable {
        case iCloudUnavailable
        case keychainUnavailable
        case networkUnavailable
        case serviceUnavailable
        case encryptionFailed
        case unknown
    }

    static let shared = CrossDeviceSyncController()
    nonisolated static let cloudContainerIdentifier = "iCloud.com.jamesli.tokenremain"
    nonisolated static let keychainAccessGroup = "84397AQ22Y.com.jamesli.tokenremain.sync"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var state: State
    @Published private(set) var lastUploadedAt: Date?
    @Published private(set) var previewProviders: [PreviewProvider] = []
    @Published private(set) var syncUsageHistoryEnabled: Bool
    @Published private(set) var previewHistoryDays = 0

    private enum DefaultsKey {
        static let enabled = "crossDeviceSync.enabled"
        static let sourceInstanceID = "crossDeviceSync.sourceInstanceID"
        static let sequence = "crossDeviceSync.sequence"
        static let lastFingerprint = "crossDeviceSync.lastFingerprint"
        static let lastUploadedAt = "crossDeviceSync.lastUploadedAt"
        static let syncUsageHistory = "crossDeviceSync.syncUsageHistory"
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.jamesli.usagedock", category: "PrivateSync")
    private var latestQuotas: [ProviderQuota.Provider: ProviderQuota] = [:]
    private var latestHistory: DailyUsageHistory?
    private var latestFeedPosts: [AIFeedPost] = []
    private var storeSubscription: AnyCancellable?
    private var historySubscription: AnyCancellable?
    private var feedSubscription: AnyCancellable?
    private var uploadTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var allowsSourceTakeoverOnce = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: DefaultsKey.enabled)
        isEnabled = enabled
        syncUsageHistoryEnabled = defaults.bool(forKey: DefaultsKey.syncUsageHistory)
        lastUploadedAt = defaults.object(forKey: DefaultsKey.lastUploadedAt) as? Date
        state = enabled ? .waitingForMacData : .off
    }

    func attach(to store: UsageStore, feedStore: AIFeedStore) {
        guard storeSubscription == nil else { return }
        latestQuotas = store.quotas
        latestHistory = store.history
        latestFeedPosts = feedStore.topStories
        updatePreview()
        storeSubscription = store.$quotas
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] quotas in
                guard let self else { return }
                self.latestQuotas = quotas
                self.updatePreview()
                self.scheduleUpload(after: 12)
            }
        historySubscription = store.$history
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] history in
                guard let self else { return }
                self.latestHistory = history
                self.updatePreview()
                self.scheduleUpload(after: 12)
            }
        feedSubscription = feedStore.$posts
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak feedStore] _ in
                guard let self, let feedStore else { return }
                self.latestFeedPosts = feedStore.topStories
                self.scheduleUpload(after: 12)
            }
        if isEnabled {
            scheduleUpload(after: 0)
            startHeartbeat()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.enabled)
        if enabled {
            retryAttempt = 0
            state = latestQuotas.isEmpty ? .waitingForMacData : .checkingICloud
            scheduleUpload(after: 0)
            startHeartbeat()
        } else {
            uploadTask?.cancel()
            uploadTask = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            state = .off
        }
    }

    func uploadNow() {
        guard isEnabled else { return }
        scheduleUpload(after: 0, forceHeartbeat: true)
    }

    func setUsageHistoryEnabled(_ enabled: Bool) {
        guard enabled != syncUsageHistoryEnabled else { return }
        syncUsageHistoryEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.syncUsageHistory)
        updatePreview()
        if isEnabled {
            scheduleUpload(after: 0, forceHeartbeat: true)
        }
    }

    func takeOverAsPrimaryMac() {
        guard isEnabled else { return }
        allowsSourceTakeoverOnce = true
        scheduleUpload(after: 0, forceHeartbeat: true)
    }

    /// Deletes only the app's fixed private CloudKit zone and dedicated sync
    /// key service. Provider credentials and ordinary local quota caches are
    /// outside both stores and cannot be removed by this operation.
    func deleteCloudDataAndDisconnect() async {
        guard SyncCapabilityProbe.hasRequiredEntitlements else {
            state = .needsSignedCapabilities
            return
        }
        uploadTask?.cancel()
        heartbeatTask?.cancel()
        do {
            let cloud = CloudKitPrivateSnapshotStore(containerIdentifier: Self.cloudContainerIdentifier)
            let keys = SynchronizableSyncKeyStore(accessGroup: Self.keychainAccessGroup)
            try await cloud.deleteZone()
            try await keys.deleteAll()
            defaults.removeObject(forKey: DefaultsKey.sourceInstanceID)
            defaults.removeObject(forKey: DefaultsKey.sequence)
            defaults.removeObject(forKey: DefaultsKey.lastFingerprint)
            defaults.removeObject(forKey: DefaultsKey.lastUploadedAt)
            defaults.removeObject(forKey: DefaultsKey.syncUsageHistory)
            lastUploadedAt = nil
            isEnabled = false
            syncUsageHistoryEnabled = false
            previewHistoryDays = 0
            defaults.set(false, forKey: DefaultsKey.enabled)
            state = .off
            logger.info("Private sync data deleted")
        } catch {
            state = .failed(Self.failure(for: error))
            logger.error("Private sync deletion failed: \(Self.errorCode(error), privacy: .public)")
        }
    }

    private func scheduleUpload(after seconds: TimeInterval, forceHeartbeat: Bool = false) {
        guard isEnabled else { return }
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            guard let self else { return }
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard !Task.isCancelled else { return }
            await self.publishLatest(forceHeartbeat: forceHeartbeat)
        }
    }

    private func publishLatest(forceHeartbeat: Bool) async {
        guard isEnabled else { return }
        guard !latestQuotas.isEmpty else {
            state = .waitingForMacData
            return
        }
        guard SyncCapabilityProbe.hasRequiredEntitlements else {
            state = .needsSignedCapabilities
            return
        }

        let fingerprint = Self.fingerprint(
            for: latestQuotas,
            history: latestHistory,
            includesUsageHistory: syncUsageHistoryEnabled,
            feedPosts: latestFeedPosts
        )
        if !forceHeartbeat,
           fingerprint == defaults.string(forKey: DefaultsKey.lastFingerprint),
           let lastUploadedAt,
           Date().timeIntervalSince(lastUploadedAt) < 15 * 60 {
            return
        }

        state = .checkingICloud
        do {
            let cloud = CloudKitPrivateSnapshotStore(containerIdentifier: Self.cloudContainerIdentifier)
            guard try await cloud.accountStatus() == .available else {
                throw SyncCloudStoreError.accountUnavailable
            }
            let localSourceID = sourceInstanceID()
            let keys = SynchronizableSyncKeyStore(accessGroup: Self.keychainAccessGroup)
            if let existing = try await cloud.fetch(),
               existing.envelope.sourceInstanceID != localSourceID,
               !allowsSourceTakeoverOnce {
                // The CloudKit record header is cleartext operational metadata.
                // Authenticate the envelope before trusting it to arbitrate the
                // primary Mac; a forged header must never block this publisher.
                let authenticatedSourceID = try await MacSyncRemoteSourceAuthenticator.sourceInstanceID(
                    from: existing,
                    keyStore: keys,
                    containerIdentifier: Self.cloudContainerIdentifier,
                    now: Date()
                )
                if authenticatedSourceID != localSourceID {
                    state = .anotherMacIsPrimary
                    return
                }
            }
            state = .uploading
            let keyRecord = try await keys.loadOrCreate()
            let sequence = nextSequence()
            let now = Date()
            let snapshot = MobileSnapshotRedactor.makeSnapshot(
                from: latestQuotas,
                history: latestHistory,
                includesUsageHistory: syncUsageHistoryEnabled,
                feedPosts: latestFeedPosts,
                sourceInstanceID: localSourceID,
                sequence: sequence,
                generatedAt: now
            )
            let envelope = try EncryptedSyncEnvelope.seal(
                snapshot,
                using: keyRecord.key,
                keyID: keyRecord.keyID,
                containerID: Self.cloudContainerIdentifier,
                configuration: .current(now: now)
            )
            try await cloud.save(envelope)

            retryAttempt = 0
            allowsSourceTakeoverOnce = false
            defaults.set(fingerprint, forKey: DefaultsKey.lastFingerprint)
            defaults.set(now, forKey: DefaultsKey.lastUploadedAt)
            lastUploadedAt = now
            state = .synced(now)
            logger.info("Private sync upload succeeded; sequence \(sequence, privacy: .public)")
        } catch {
            let failure = Self.failure(for: error)
            state = .failed(failure)
            logger.error("Private sync upload failed: \(Self.errorCode(error), privacy: .public)")
            retryAttempt = min(retryAttempt + 1, 8)
            let delay = min(pow(2, Double(retryAttempt)), 300)
            scheduleUpload(after: delay, forceHeartbeat: forceHeartbeat)
        }
    }

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard let self, !Task.isCancelled, self.isEnabled else { return }
                await self.publishLatest(forceHeartbeat: true)
            }
        }
    }

    private func sourceInstanceID() -> UUID {
        if let value = defaults.string(forKey: DefaultsKey.sourceInstanceID),
           let identifier = UUID(uuidString: value) {
            return identifier
        }
        let identifier = UUID()
        defaults.set(identifier.uuidString.lowercased(), forKey: DefaultsKey.sourceInstanceID)
        return identifier
    }

    private func updatePreview() {
        previewProviders = MobileSnapshotRedactor.publishedProviders.compactMap { provider in
            guard let quota = latestQuotas[provider] else { return nil }
            return PreviewProvider(
                id: MobileSnapshotRedactor.stableID(for: provider),
                windows: [quota.primary, quota.secondary].compactMap { $0 }.map {
                    PreviewProvider.Window(
                        usedPercent: min(max($0.usedPercent, 0), 100),
                        windowMinutes: max(0, $0.windowMinutes),
                        resetsAt: $0.resetsAt
                    )
                },
                capturedAt: quota.capturedAt
            )
        }
        previewHistoryDays = syncUsageHistoryEnabled ? (latestHistory?.days.count ?? 0) : 0
    }

    private func nextSequence() -> UInt64 {
        let current = UInt64(max(0, defaults.integer(forKey: DefaultsKey.sequence)))
        let next = current == UInt64.max ? 1 : current + 1
        defaults.set(Int(clamping: next), forKey: DefaultsKey.sequence)
        return next
    }

    private static func fingerprint(
        for quotas: [ProviderQuota.Provider: ProviderQuota],
        history: DailyUsageHistory?,
        includesUsageHistory: Bool,
        feedPosts: [AIFeedPost]
    ) -> String {
        struct FingerprintWindow: Codable {
            let usedPercent: Double
            let windowMinutes: Int
            let resetsAt: Date?
        }
        struct FingerprintProvider: Codable {
            let id: String
            let capturedAt: Date
            let planName: String?
            let windows: [FingerprintWindow]
        }
        struct FingerprintPayload: Codable {
            let providers: [FingerprintProvider]
            let history: DailyUsageHistory?
            let curatedPosts: [SyncedCuratedPost]
        }
        let values = MobileSnapshotRedactor.publishedProviders.compactMap { provider -> FingerprintProvider? in
            guard let quota = quotas[provider] else { return nil }
            return FingerprintProvider(
                id: MobileSnapshotRedactor.stableID(for: provider),
                capturedAt: quota.capturedAt,
                planName: SyncedProviderQuota.sanitizedPlanName(quota.planName),
                windows: [quota.primary, quota.secondary].compactMap { $0 }.map {
                    FingerprintWindow(
                        usedPercent: min(max($0.usedPercent, 0), 100),
                        windowMinutes: max(0, $0.windowMinutes),
                        resetsAt: $0.resetsAt
                    )
                }
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = FingerprintPayload(
            providers: values,
            history: includesUsageHistory ? history : nil,
            curatedPosts: MobileSnapshotRedactor.curatedFeed(
                from: feedPosts,
                generatedAt: Date()
            )?.posts ?? []
        )
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(for error: Error) -> Failure {
        if let cloud = error as? SyncCloudStoreError {
            switch cloud {
            case .accountUnavailable, .notAuthenticated, .permissionDenied: return .iCloudUnavailable
            case .networkUnavailable: return .networkUnavailable
            case .serviceUnavailable, .requestRateLimited, .conflict: return .serviceUnavailable
            case .recordNotFound, .zoneNotFound, .malformedRecord, .unknown: return .unknown
            }
        }
        if error is SyncKeyStoreError { return .keychainUnavailable }
        if error is SyncProtocolError || error is SyncValidationError { return .encryptionFailed }
        return .unknown
    }

    private static func errorCode(_ error: Error) -> String {
        if let cloud = error as? SyncCloudStoreError { return "cloud:\(String(describing: cloud))" }
        if let keychain = error as? SyncKeyStoreError { return "keychain:\(String(describing: keychain))" }
        if error is SyncProtocolError { return "protocol" }
        if error is SyncValidationError { return "validation" }
        return "unknown"
    }
}

/// Clear CloudKit metadata is useful for lookup and ordering, but it is never an
/// authorization boundary. This helper returns a source ID only after the AES-GCM
/// envelope and its embedded snapshot have both been authenticated and validated.
enum MacSyncRemoteSourceAuthenticator {
    static func sourceInstanceID(
        from stored: SyncCloudStoredEnvelope,
        keyStore: any SyncKeyStoring,
        containerIdentifier: String,
        now: Date = Date()
    ) async throws -> UUID {
        guard let keyRecord = try await keyStore.load(keyID: stored.envelope.keyID) else {
            throw SyncKeyStoreError.currentKeyMissing(stored.envelope.keyID)
        }
        let snapshot = try stored.envelope.open(
            using: keyRecord.key,
            containerID: containerIdentifier,
            supportedProviderIDs: SyncedProviderID.supportedOnCurrentMobile,
            configuration: .current(now: now)
        )
        return snapshot.sourceInstanceID
    }
}

private enum SyncCapabilityProbe {
    static var hasRequiredEntitlements: Bool {
        let containers = values(for: "com.apple.developer.icloud-container-identifiers")
        let keychainGroups = values(for: "keychain-access-groups")
        return containers.contains(CrossDeviceSyncController.cloudContainerIdentifier)
            && keychainGroups.contains(CrossDeviceSyncController.keychainAccessGroup)
    }

    private static func values(for entitlement: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        else { return [] }
        return value as? [String] ?? []
    }
}
#endif
