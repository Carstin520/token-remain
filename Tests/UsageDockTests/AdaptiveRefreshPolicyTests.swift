import Foundation
import Testing
@testable import UsageDock

@Suite("Adaptive provider refresh policy")
struct AdaptiveRefreshPolicyTests {
    @Test("Apple sync forces one-minute capture without changing idle preference")
    func activeOverride() {
        #expect(AdaptiveRefreshPolicy.interval(preferred: 300, lowLatencySyncEnabled: false) == 300)
        #expect(AdaptiveRefreshPolicy.interval(preferred: nil, lowLatencySyncEnabled: false) == nil)
        #expect(AdaptiveRefreshPolicy.interval(preferred: 1_800, lowLatencySyncEnabled: true) == 60)
        #expect(AdaptiveRefreshPolicy.interval(preferred: nil, lowLatencySyncEnabled: true) == 60)
    }

    @Test("Provider errors back off independently and cap at five minutes")
    func cappedBackoff() {
        #expect(AdaptiveRefreshPolicy.retryDelay(after: 0) == 0)
        #expect(AdaptiveRefreshPolicy.retryDelay(after: 1) == 60)
        #expect(AdaptiveRefreshPolicy.retryDelay(after: 2) == 120)
        #expect(AdaptiveRefreshPolicy.retryDelay(after: 3) == 240)
        #expect(AdaptiveRefreshPolicy.retryDelay(after: 4) == 300)
        #expect(AdaptiveRefreshPolicy.retryDelay(after: 9) == 300)
    }

    #if TOKENREMAIN_CLOUD_SYNC
    @Test("Sync fingerprint ignores capture-only churn but detects quota changes")
    func contentFingerprint() {
        let start = Date(timeIntervalSince1970: 1_784_764_800)
        func quota(usedPercent: Double, capturedAt: Date) -> ProviderQuota {
            ProviderQuota(
                provider: .claude,
                primary: QuotaWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: start + 300
                ),
                secondary: nil,
                planName: "Pro",
                capturedAt: capturedAt
            )
        }
        let first = SyncContentFingerprint.make(
            quotas: [.claude: quota(usedPercent: 42, capturedAt: start)],
            history: nil,
            includesUsageHistory: false
        )
        let recaptured = SyncContentFingerprint.make(
            quotas: [.claude: quota(usedPercent: 42, capturedAt: start + 60)],
            history: nil,
            includesUsageHistory: false
        )
        let changed = SyncContentFingerprint.make(
            quotas: [.claude: quota(usedPercent: 43, capturedAt: start + 60)],
            history: nil,
            includesUsageHistory: false
        )
        #expect(first == recaptured)
        #expect(first != changed)
    }
    #endif
}
