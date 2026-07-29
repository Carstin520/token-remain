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

    @Test("Local usage keeps minute cadence only for visible UI or Apple sync")
    func localUsageInterval() {
        // 同步或任一本地用量界面可见 → 分钟级。
        #expect(AdaptiveRefreshPolicy.localUsageInterval(
            preferred: 300, lowLatencySyncEnabled: true, localUsageUIVisible: false
        ) == 60)
        #expect(AdaptiveRefreshPolicy.localUsageInterval(
            preferred: nil, lowLatencySyncEnabled: false, localUsageUIVisible: true
        ) == 60)
        // 后台空闲 → 跟随用户偏好;"仅手动"档不做后台扫描。
        #expect(AdaptiveRefreshPolicy.localUsageInterval(
            preferred: 300, lowLatencySyncEnabled: false, localUsageUIVisible: false
        ) == 300)
        #expect(AdaptiveRefreshPolicy.localUsageInterval(
            preferred: nil, lowLatencySyncEnabled: false, localUsageUIVisible: false
        ) == nil)
    }

    @Test("Local usage due check honors the interval and presentation can force it")
    func localUsageCadence() {
        let now = Date(timeIntervalSince1970: 1_784_966_400)

        #expect(AdaptiveRefreshPolicy.localUsageRefreshIsDue(
            interval: 60,
            lastRefresh: nil,
            now: now,
            force: false
        ))
        #expect(!AdaptiveRefreshPolicy.localUsageRefreshIsDue(
            interval: 60,
            lastRefresh: now.addingTimeInterval(-59),
            now: now,
            force: false
        ))
        #expect(AdaptiveRefreshPolicy.localUsageRefreshIsDue(
            interval: 60,
            lastRefresh: now.addingTimeInterval(-60),
            now: now,
            force: false
        ))
        #expect(AdaptiveRefreshPolicy.localUsageRefreshIsDue(
            interval: 300,
            lastRefresh: now.addingTimeInterval(-299),
            now: now,
            force: false
        ) == false)
        // "仅手动"档没有自动节奏,但打开界面的强制刷新永远放行。
        #expect(!AdaptiveRefreshPolicy.localUsageRefreshIsDue(
            interval: nil,
            lastRefresh: nil,
            now: now,
            force: false
        ))
        #expect(AdaptiveRefreshPolicy.localUsageRefreshIsDue(
            interval: nil,
            lastRefresh: now,
            now: now,
            force: true
        ))
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
