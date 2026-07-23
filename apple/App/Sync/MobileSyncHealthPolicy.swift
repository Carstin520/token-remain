import Foundation

enum MobileSyncGuidance: String, Identifiable, Sendable {
    case openMac
    case checkICloud
    case checkKeychain

    var id: String { rawValue }
}

enum MobileSyncHealthPolicy {
    private static let initialRetryDelays: [TimeInterval] = [2, 5, 10, 30, 60]

    static func retryDelay(afterAttempt attempt: Int, state: MobileSyncState) -> TimeInterval {
        switch state {
        case .off, .synced, .sourceChangeRequiresConfirmation:
            return 45
        case .pulling, .waitingForMac, .waitingForKey, .failed:
            guard attempt < initialRetryDelays.count else { return 45 }
            return initialRetryDelays[max(0, attempt)]
        }
    }

    static func guidance(for state: MobileSyncState) -> MobileSyncGuidance? {
        switch state {
        case .waitingForMac:
            return .openMac
        case .waitingForKey:
            return .checkKeychain
        case .failed(let failure):
            switch failure {
            case .iCloudAccountUnavailable, .iCloudAccountRestricted,
                 .iCloudAccountUnknown, .iCloudAuthenticationRequired,
                 .iCloudPermissionDenied:
                return .checkICloud
            case .iCloudTemporarilyUnavailable, .networkUnavailable,
                 .serviceUnavailable, .rateLimited, .syncConflict,
                 .remoteRecordUnavailable, .untrustedRemotePayload,
                 .syncKeyUnavailable, .localReplayStateUnavailable:
                return nil
            }
        case .off, .pulling, .synced, .sourceChangeRequiresConfirmation:
            return nil
        }
    }

    static func graceInterval(for guidance: MobileSyncGuidance) -> TimeInterval {
        switch guidance {
        case .checkICloud:
            return 10
        case .openMac, .checkKeychain:
            return 120
        }
    }
}
