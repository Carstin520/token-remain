@preconcurrency import CloudKit
import Foundation
import TokenRemainKit
import TokenRemainSyncKit

/// Stable, redacted states the iPhone can surface or retry from. No case carries
/// a CloudKit record, a Keychain value, provider data, or an underlying error.
enum MobileSyncFailure: Sendable, Equatable {
    case iCloudAccountUnavailable
    case iCloudAccountRestricted
    case iCloudTemporarilyUnavailable
    case iCloudAccountUnknown
    case iCloudAuthenticationRequired
    case iCloudPermissionDenied
    case networkUnavailable
    case serviceUnavailable
    case rateLimited(retryAfterSeconds: Double?)
    case syncConflict
    case remoteRecordUnavailable
    case untrustedRemotePayload
    case syncKeyUnavailable
    case localReplayStateUnavailable
}

enum MobileSyncNoChangeReason: Sendable, Equatable {
    case noRemoteSnapshot
    case duplicate
    case olderSequence
}

/// A source candidate is deliberately header-only. It lets the UI request a
/// source-change confirmation without exposing a quota payload that has not yet
/// been accepted by the replay guard.
struct MobileSyncSourceCandidate: Sendable, Equatable {
    let marker: SyncReplayMarker
}

/// The main app decides how to fan a received DTO out to its local presentation
/// surfaces. This client never writes App Group snapshot files, Widget data,
/// Live Activities, or WatchConnectivity state directly.
enum MobileSyncPullOutcome: Sendable, Equatable {
    case updated(MobileSyncDelivery)
    case noChange(MobileSyncNoChangeReason)
    case requiresSourceConfirmation(MobileSyncSourceCandidate)
    case failed(MobileSyncFailure)
}

/// iPhone-only CloudKit pull coordinator. It operates exclusively on the
/// user's CloudKit private database through `SyncCloudSnapshotStoring`, obtains
/// only an AES key by ID from the dedicated synchronizable Keychain store, then
/// returns a strict, authenticated DTO to the main app.
actor MobileSyncClient {
    static let defaultContainerIdentifier = "iCloud.com.jamesli.tokenremain"
    static let defaultKeychainAccessGroup = "84397AQ22Y.com.jamesli.tokenremain.sync"
    static let shared = MobileSyncClient()
    private static let replayMarkerDefaultsKey = "tr.mobileSync.replayMarker.v1"

    private let cloudStore: any SyncCloudSnapshotStoring
    private let keyStore: any SyncKeyStoring
    private let containerIdentifier: String
    private let defaultsSuiteName: String?
    private var replayGuard: SyncReplayGuard

    /// Production convenience initializer. The access group must match the
    /// signed entitlement on both apps; it is explicit so a Team/profile change
    /// cannot silently fall back to an app-private Keychain group.
    init(
        containerIdentifier: String = MobileSyncClient.defaultContainerIdentifier,
        keychainAccessGroup: String = MobileSyncClient.defaultKeychainAccessGroup,
        defaultsSuiteName: String? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.defaultsSuiteName = defaultsSuiteName
        #if targetEnvironment(simulator)
        // CKContainer raises an Objective-C exception when a simulator host is
        // intentionally built without real CloudKit signing. Keep demo/UI tests
        // honest and non-crashing; real CloudKit E2E belongs on signed devices.
        self.cloudStore = SimulatorUnavailableCloudStore()
        #else
        self.cloudStore = CloudKitPrivateSnapshotStore(containerIdentifier: containerIdentifier)
        #endif
        self.keyStore = SynchronizableSyncKeyStore(
            accessGroup: keychainAccessGroup
        )
        self.replayGuard = SyncReplayGuard(latest: Self.loadReplayMarker(suiteName: defaultsSuiteName))
    }

    /// Injection initializer for deterministic tests. The collaborators are
    /// intentionally protocol-typed; this actor never needs a real CloudKit
    /// account or iCloud Keychain to exercise validation and replay handling.
    init(
        cloudStore: any SyncCloudSnapshotStoring,
        keyStore: any SyncKeyStoring,
        containerIdentifier: String = MobileSyncClient.defaultContainerIdentifier,
        defaultsSuiteName: String? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.defaultsSuiteName = defaultsSuiteName
        self.cloudStore = cloudStore
        self.keyStore = keyStore
        self.replayGuard = SyncReplayGuard(latest: Self.loadReplayMarker(suiteName: defaultsSuiteName))
    }

    /// Pulls the one fixed encrypted record. A remote notification is only a
    /// hint to call this method; correctness always comes from refetching,
    /// decrypting, validating, and replay-checking the current record.
    func pull(
        confirmedSourceChange: SyncReplayMarker? = nil,
        now: Date = Date(),
        phoneReceivedAt: Date? = nil
    ) async -> MobileSyncPullOutcome {
        do {
            switch try await cloudStore.accountStatus() {
            case .available:
                break
            case .noAccount:
                return .failed(.iCloudAccountUnavailable)
            case .restricted:
                return .failed(.iCloudAccountRestricted)
            case .temporarilyUnavailable:
                return .failed(.iCloudTemporarilyUnavailable)
            case .couldNotDetermine:
                return .failed(.iCloudAccountUnknown)
            }

            // Keep the subscription scoped to the fixed custom zone, then read
            // the record. Neither operation sends quota values in a push payload.
            try await cloudStore.ensureZone()
            try await cloudStore.ensureSubscription()
            guard let stored = try await cloudStore.fetch() else {
                resetReplayState()
                return .noChange(.noRemoteSnapshot)
            }

            guard let keyRecord = try await keyStore.load(keyID: stored.envelope.keyID) else {
                // Deliberately do not call loadOrCreate here. A receiving iPhone
                // must never mint a second key while iCloud Keychain propagation
                // is pending, because that would make the Mac's ciphertext unreadable.
                return .failed(.syncKeyUnavailable)
            }

            let configuration = SyncValidationConfiguration(now: now)
            let snapshot = try stored.envelope.open(
                using: keyRecord.key,
                containerID: containerIdentifier,
                supportedProviderIDs: SyncedProviderID.supportedOnCurrentMobile,
                configuration: configuration
            )
            return try evaluateReplay(
                snapshot,
                confirmedSourceChange: confirmedSourceChange,
                configuration: configuration,
                macUploadedAt: stored.macUploadedAt,
                phoneReceivedAt: phoneReceivedAt ?? Date()
            )
        } catch let error as SyncCloudStoreError {
            return .failed(Self.mapCloudError(error))
        } catch is SyncKeyStoreError {
            return .failed(.syncKeyUnavailable)
        } catch is SyncProtocolError {
            return .failed(.untrustedRemotePayload)
        } catch is SyncValidationError {
            return .failed(.untrustedRemotePayload)
        } catch {
            // This is intentionally broad at the boundary: no underlying error
            // text is retained or surfaced from a background sync operation.
            return .failed(.untrustedRemotePayload)
        }
    }

    /// A local opt-out or confirmed remote deletion starts a fresh trust epoch.
    /// This removes only the non-sensitive replay marker, never the sync key.
    func resetReplayState() {
        replayGuard = SyncReplayGuard()
        defaults().removeObject(forKey: Self.replayMarkerDefaultsKey)
    }

    private func evaluateReplay(
        _ snapshot: MobileUsageSnapshot,
        confirmedSourceChange: SyncReplayMarker?,
        configuration: SyncValidationConfiguration,
        macUploadedAt: Date?,
        phoneReceivedAt: Date
    ) throws -> MobileSyncPullOutcome {
        let previousGuard = replayGuard
        let decision = try replayGuard.evaluate(
            snapshot,
            confirmedSourceChange: confirmedSourceChange,
            configuration: configuration
        )
        switch decision {
        case .accepted:
            guard let marker = replayGuard.latest, persistReplayMarker(marker) else {
                replayGuard = previousGuard
                return .failed(.localReplayStateUnavailable)
            }
            return .updated(MobileSyncDelivery(
                snapshot: snapshot,
                macUploadedAt: macUploadedAt,
                phoneReceivedAt: phoneReceivedAt
            ))
        case .duplicate:
            return .noChange(.duplicate)
        case .replayedOlderSequence, .conflictingSequence:
            return .noChange(.olderSequence)
        case .sourceChangeRequiresConfirmation:
            return .requiresSourceConfirmation(
                MobileSyncSourceCandidate(marker: SyncReplayMarker(
                    sourceInstanceID: snapshot.sourceInstanceID,
                    sequence: snapshot.sequence,
                    generatedAt: snapshot.generatedAt
                ))
            )
        }
    }

    private func persistReplayMarker(_ marker: SyncReplayMarker) -> Bool {
        guard let data = try? JSONEncoder().encode(marker) else {
            return false
        }
        defaults().set(data, forKey: Self.replayMarkerDefaultsKey)
        return true
    }

    private func defaults() -> UserDefaults {
        defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    private static func loadReplayMarker(suiteName: String?) -> SyncReplayMarker? {
        let defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        guard let data = defaults.data(forKey: replayMarkerDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SyncReplayMarker.self, from: data)
    }

    private static func mapCloudError(_ error: SyncCloudStoreError) -> MobileSyncFailure {
        switch error {
        case .accountUnavailable:
            return .iCloudAccountUnknown
        case .notAuthenticated:
            return .iCloudAuthenticationRequired
        case .permissionDenied:
            return .iCloudPermissionDenied
        case .networkUnavailable:
            return .networkUnavailable
        case .serviceUnavailable:
            return .serviceUnavailable
        case .requestRateLimited(let retryAfterSeconds):
            return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case .conflict:
            return .syncConflict
        case .recordNotFound, .zoneNotFound:
            return .remoteRecordUnavailable
        case .malformedRecord:
            return .untrustedRemotePayload
        case .unknown:
            return .serviceUnavailable
        }
    }
}

#if targetEnvironment(simulator)
private actor SimulatorUnavailableCloudStore: SyncCloudSnapshotStoring {
    func accountStatus() async throws -> SyncCloudAccountStatus { .noAccount }
    func ensureZone() async throws { throw SyncCloudStoreError.accountUnavailable }
    func save(_ envelope: EncryptedSyncEnvelope) async throws { throw SyncCloudStoreError.accountUnavailable }
    func fetch() async throws -> SyncCloudStoredEnvelope? { throw SyncCloudStoreError.accountUnavailable }
    func deleteCurrent() async throws { throw SyncCloudStoreError.accountUnavailable }
    func deleteZone() async throws { throw SyncCloudStoreError.accountUnavailable }
    func ensureSubscription() async throws { throw SyncCloudStoreError.accountUnavailable }
}
#endif

/// Remote notifications are intentionally reduced to a subscription-ID check.
/// No payload field is interpreted as quota data, and matching only signals the
/// app to run `MobileSyncClient.pull()`.
enum MobileSyncRemoteNotification {
    static func shouldTriggerPull(for userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return false
        }
        return notification.subscriptionID == CloudKitPrivateSnapshotStore.subscriptionID
    }
}
