#if TOKENREMAIN_CLOUD_SYNC
import CloudKit
import Combine
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

    enum Guidance: String, Identifiable, Equatable {
        case checkICloud
        case checkKeychain

        var id: String { rawValue }
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
    @Published private(set) var lastAutomaticCheckAt: Date?
    @Published private(set) var iCloudAvailable: Bool?
    @Published private(set) var syncKeyAvailable: Bool?
    @Published private(set) var guidance: Guidance?

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
    private var accountSubscription: AnyCancellable?
    private var uploadTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var allowsSourceTakeoverOnce = false
    private weak var usageStore: UsageStore?
    private var currentGuidanceIssue: Guidance?
    private var guidanceIssueBeganAt: Date?
    private var dismissedGuidanceIssue: Guidance?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Fresh installs participate automatically. Once the user turns sync
        // off, the explicit stored false remains authoritative.
        let enabled = (defaults.object(forKey: DefaultsKey.enabled) as? Bool) ?? true
        isEnabled = enabled
        syncUsageHistoryEnabled = defaults.bool(forKey: DefaultsKey.syncUsageHistory)
        lastUploadedAt = defaults.object(forKey: DefaultsKey.lastUploadedAt) as? Date
        state = enabled ? .waitingForMacData : .off
    }

    func attach(to store: UsageStore, feedStore: AIFeedStore) {
        guard storeSubscription == nil else { return }
        usageStore = store
        store.setLowLatencySyncEnabled(isEnabled)
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
                self.scheduleUpload(after: 4)
            }
        historySubscription = store.$history
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] history in
                guard let self else { return }
                self.latestHistory = history
                self.updatePreview()
                self.scheduleUpload(after: 4)
            }
        feedSubscription = feedStore.$posts
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak feedStore] _ in
                guard let self, let feedStore else { return }
                self.latestFeedPosts = feedStore.topStories
                self.scheduleUpload(after: 4)
            }
        accountSubscription = NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleICloudAccountChanged()
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
        usageStore?.setLowLatencySyncEnabled(enabled)
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
            iCloudAvailable = nil
            syncKeyAvailable = nil
            clearGuidanceIssue()
        }
    }

    func uploadNow() {
        guard isEnabled else { return }
        scheduleUpload(after: 0, forceHeartbeat: true)
    }

    func checkNow() {
        guard isEnabled else { return }
        scheduleUpload(after: 0, forceHeartbeat: true)
    }

    func dismissGuidance() {
        dismissedGuidanceIssue = guidance
        guidance = nil
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
            iCloudAvailable = nil
            syncKeyAvailable = nil
            clearGuidanceIssue()
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
        let checkedAt = Date()
        lastAutomaticCheckAt = checkedAt
        guard SyncCapabilityProbe.hasRequiredEntitlements else {
            state = .needsSignedCapabilities
            iCloudAvailable = nil
            syncKeyAvailable = nil
            return
        }

        state = .checkingICloud
        do {
            let cloud = CloudKitPrivateSnapshotStore(containerIdentifier: Self.cloudContainerIdentifier)
            guard try await cloud.accountStatus() == .available else {
                throw SyncCloudStoreError.accountUnavailable
            }
            iCloudAvailable = true
            let localSourceID = sourceInstanceID()
            let keys = SynchronizableSyncKeyStore(accessGroup: Self.keychainAccessGroup)
            let keyRecord = try await keys.loadOrCreate()
            syncKeyAvailable = true
            clearGuidanceIssue()

            guard !latestQuotas.isEmpty else {
                retryAttempt = 0
                state = .waitingForMacData
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
               checkedAt.timeIntervalSince(lastUploadedAt) < 15 * 60 {
                state = .synced(lastUploadedAt)
                return
            }

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
            let sequence = nextSequence()
            let preparedAt = Date()
            let snapshot = MobileSnapshotRedactor.makeSnapshot(
                from: latestQuotas,
                history: latestHistory,
                includesUsageHistory: syncUsageHistoryEnabled,
                feedPosts: latestFeedPosts,
                sourceInstanceID: localSourceID,
                sequence: sequence,
                generatedAt: preparedAt
            )
            let envelope = try EncryptedSyncEnvelope.seal(
                snapshot,
                using: keyRecord.key,
                keyID: keyRecord.keyID,
                containerID: Self.cloudContainerIdentifier,
                configuration: .current(now: preparedAt)
            )
            try await cloud.save(envelope)
            let uploadedAt = Date()

            retryAttempt = 0
            allowsSourceTakeoverOnce = false
            defaults.set(fingerprint, forKey: DefaultsKey.lastFingerprint)
            defaults.set(uploadedAt, forKey: DefaultsKey.lastUploadedAt)
            lastUploadedAt = uploadedAt
            state = .synced(uploadedAt)
            logger.info("Private sync upload succeeded; sequence \(sequence, privacy: .public)")
        } catch {
            let failure = Self.failure(for: error)
            state = .failed(failure)
            if failure == .iCloudUnavailable {
                iCloudAvailable = false
                syncKeyAvailable = nil
            } else if failure == .keychainUnavailable {
                iCloudAvailable = true
                syncKeyAvailable = false
            }
            updateGuidance(for: failure, at: checkedAt)
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

    private func handleICloudAccountChanged() {
        guard isEnabled else { return }
        iCloudAvailable = nil
        syncKeyAvailable = nil
        clearGuidanceIssue()
        scheduleUpload(after: 0, forceHeartbeat: true)
    }

    private func updateGuidance(for failure: Failure, at now: Date) {
        let issue: Guidance? = switch failure {
        case .iCloudUnavailable: .checkICloud
        case .keychainUnavailable: .checkKeychain
        case .networkUnavailable, .serviceUnavailable, .encryptionFailed, .unknown: nil
        }
        guard issue == currentGuidanceIssue else {
            currentGuidanceIssue = issue
            guidanceIssueBeganAt = issue == nil ? nil : now
            dismissedGuidanceIssue = nil
            guidance = nil
            return
        }
        guard let issue, dismissedGuidanceIssue != issue else { return }
        let beganAt = guidanceIssueBeganAt ?? now
        guidanceIssueBeganAt = beganAt
        if now.timeIntervalSince(beganAt) >= 15 {
            guidance = issue
        }
    }

    private func clearGuidanceIssue() {
        currentGuidanceIssue = nil
        guidanceIssueBeganAt = nil
        dismissedGuidanceIssue = nil
        guidance = nil
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
        SyncContentFingerprint.make(
            quotas: quotas,
            history: history,
            includesUsageHistory: includesUsageHistory,
            feedPosts: feedPosts
        )
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
