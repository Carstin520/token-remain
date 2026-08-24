import Foundation
import Testing
@testable import UsageDock

@Suite("Adaptive provider refresh policy")
struct AdaptiveRefreshPolicyTests {
    @Test("Local sessions stay live while idle account polling has a five-minute floor")
    func localAIIntervals() {
        #expect(AdaptiveRefreshPolicy.localAIQuotaInterval(
            preferred: 300,
            lowLatencySyncEnabled: false,
            localSessionActive: true,
            primarySurfaceVisible: false
        ) == 60)
        #expect(AdaptiveRefreshPolicy.localAIQuotaInterval(
            preferred: 60,
            lowLatencySyncEnabled: false,
            localSessionActive: false,
            primarySurfaceVisible: false
        ) == 300)
        #expect(AdaptiveRefreshPolicy.localAIQuotaInterval(
            preferred: 1_800,
            lowLatencySyncEnabled: false,
            localSessionActive: false,
            primarySurfaceVisible: false
        ) == 1_800)
        #expect(AdaptiveRefreshPolicy.localAIQuotaInterval(
            preferred: nil,
            lowLatencySyncEnabled: true,
            localSessionActive: false,
            primarySurfaceVisible: false
        ) == 300)
        #expect(AdaptiveRefreshPolicy.localAIQuotaInterval(
            preferred: nil,
            lowLatencySyncEnabled: true,
            localSessionActive: true,
            primarySurfaceVisible: false
        ) == 60)
        #expect(AdaptiveRefreshPolicy.localAIQuotaInterval(
            preferred: nil,
            lowLatencySyncEnabled: false,
            localSessionActive: true,
            primarySurfaceVisible: false
        ) == nil)
    }

    @Test("Scheduler and Codex scans slow down only when both sessions and UI are idle")
    func schedulerIntervals() {
        #expect(AdaptiveRefreshPolicy.schedulerInterval(
            localSessionActive: true,
            primarySurfaceVisible: false,
            auxiliaryQuotaInterval: 1_800
        ) == 60)
        #expect(AdaptiveRefreshPolicy.schedulerInterval(
            localSessionActive: false,
            primarySurfaceVisible: true,
            auxiliaryQuotaInterval: nil
        ) == 60)
        #expect(AdaptiveRefreshPolicy.schedulerInterval(
            localSessionActive: false,
            primarySurfaceVisible: false,
            auxiliaryQuotaInterval: nil
        ) == 300)
        #expect(AdaptiveRefreshPolicy.schedulerInterval(
            localSessionActive: false,
            primarySurfaceVisible: false,
            auxiliaryQuotaInterval: 60
        ) == 60)
        #expect(AdaptiveRefreshPolicy.codexLocalSnapshotInterval(
            localSessionActive: false,
            primarySurfaceVisible: false
        ) == 300)
    }

    @Test("Unrelated providers retain the user's cadence")
    func auxiliaryIntervals() {
        #expect(AdaptiveRefreshPolicy.auxiliaryQuotaInterval(
            preferred: 60,
            lowLatencySyncEnabled: false
        ) == 60)
        #expect(AdaptiveRefreshPolicy.auxiliaryQuotaInterval(
            preferred: nil,
            lowLatencySyncEnabled: false
        ) == nil)
        #expect(AdaptiveRefreshPolicy.auxiliaryQuotaInterval(
            preferred: nil,
            lowLatencySyncEnabled: true
        ) == 300)
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

    @Test("Claude fallback failures double from their base delay and cap at thirty minutes")
    func escalatedBackoff() {
        #expect(AdaptiveRefreshPolicy.escalatedRetryDelay(base: 300, consecutiveFailures: 1) == 300)
        #expect(AdaptiveRefreshPolicy.escalatedRetryDelay(base: 300, consecutiveFailures: 2) == 600)
        #expect(AdaptiveRefreshPolicy.escalatedRetryDelay(base: 300, consecutiveFailures: 3) == 1200)
        #expect(AdaptiveRefreshPolicy.escalatedRetryDelay(base: 300, consecutiveFailures: 4) == 1800)
        #expect(AdaptiveRefreshPolicy.escalatedRetryDelay(base: 300, consecutiveFailures: 9) == 1800)
        // 服务端 Retry-After 直接作为首次底数时同样不被放大到第一档以下。
        #expect(AdaptiveRefreshPolicy.escalatedRetryDelay(base: 60, consecutiveFailures: 1) == 60)
    }

    @Test("Local usage keeps minute cadence only for visible UI or Apple sync")
    func localUsageInterval() {
        // 同步或任一本地用量界面可见 → 分钟级。
        #expect(AdaptiveRefreshPolicy.localUsageInterval(
            preferred: 300,
            lowLatencySyncEnabled: true,
            localUsageUIVisible: false,
            localSessionActive: true
        ) == 60)
        #expect(AdaptiveRefreshPolicy.localUsageInterval(
            preferred: nil,
            lowLatencySyncEnabled: false,
            localUsageUIVisible: true,
            localSessionActive: false
        ) == 60)
        // 后台空闲 → 跟随用户偏好;"仅手动"档不做后台扫描。
        #expect(AdaptiveRefreshPolicy.localUsageInterval(
            preferred: 300,
            lowLatencySyncEnabled: false,
            localUsageUIVisible: false,
            localSessionActive: false
        ) == 300)
        #expect(AdaptiveRefreshPolicy.localUsageInterval(
            preferred: nil,
            lowLatencySyncEnabled: false,
            localUsageUIVisible: false,
            localSessionActive: false
        ) == nil)
        #expect(AdaptiveRefreshPolicy.localUsageInterval(
            preferred: nil,
            lowLatencySyncEnabled: true,
            localUsageUIVisible: false,
            localSessionActive: false
        ) == 300)
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
        func quota(
            usedPercent: Double,
            capturedAt: Date,
            balance: Double = 10
        ) -> ProviderQuota {
            ProviderQuota(
                provider: .claude,
                primary: QuotaWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: start + 300,
                    remainingBalance: QuotaBalance(amount: balance, currencyCode: "USD")
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
        let balanceChanged = SyncContentFingerprint.make(
            quotas: [.claude: quota(
                usedPercent: 42,
                capturedAt: start + 60,
                balance: 9
            )],
            history: nil,
            includesUsageHistory: false
        )
        #expect(first == recaptured)
        #expect(first != changed)
        #expect(first != balanceChanged)
    }
    #endif
}
