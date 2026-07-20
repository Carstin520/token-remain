import Foundation

/// Pure, view-independent derivations over a `UsageSnapshot`.
/// Ported from `Support/UsageInsights.swift` with all SwiftUI/colour helpers removed
/// and `now` promoted to an explicit parameter everywhere.
public struct UsageInsights: Sendable, Equatable {
    public let claude: ProviderQuota?
    public let codex: ProviderQuota?
    public let dailyTokens: [AgentTokens]?

    public init(claude: ProviderQuota?, codex: ProviderQuota?, dailyTokens: [AgentTokens]?) {
        self.claude = claude
        self.codex = codex
        self.dailyTokens = dailyTokens
    }

    public init(snapshot: UsageSnapshot) {
        self.init(
            claude: snapshot.providers.first { $0.provider == .claude },
            codex: snapshot.providers.first { $0.provider == .codex },
            dailyTokens: snapshot.dailyTokens
        )
    }

    // MARK: - Quota windows

    public struct Window: Identifiable, Sendable, Equatable {
        public let id: String
        public let provider: ProviderQuota.Provider
        public let slot: String
        public let windowMinutes: Int
        public let usedPercent: Double
        public let remainingPercent: Double
        public let resetsAt: Date?

        public var isPrimary: Bool { slot == "primary" }
        public var title: String { UsageFormatting.windowTitle(provider: provider, minutes: windowMinutes) }
    }

    public struct PaceAssessment: Sendable, Equatable {
        public let window: Window
        public let pace: UsagePace
    }

    /// Every official window currently known, in provider then primary→secondary order.
    public var windows: [Window] {
        var result: [Window] = []
        for quota in [claude, codex].compactMap({ $0 }) {
            result.append(window(quota.primary, provider: quota.provider, slot: "primary"))
            if let secondary = quota.secondary {
                result.append(window(secondary, provider: quota.provider, slot: "secondary"))
            }
        }
        return result
    }

    public func windows(for provider: ProviderQuota.Provider) -> [Window] {
        windows.filter { $0.provider == provider }
    }

    /// The window a provider card should lead with: its scarcest one.
    public func leadWindow(for provider: ProviderQuota.Provider) -> Window? {
        windows(for: provider).min { $0.remainingPercent < $1.remainingPercent }
    }

    private func window(_ source: QuotaWindow, provider: ProviderQuota.Provider, slot: String) -> Window {
        Window(
            id: "\(provider.rawValue)-\(slot)-\(source.windowMinutes)",
            provider: provider,
            slot: slot,
            windowMinutes: source.windowMinutes,
            usedPercent: min(100, max(0, source.usedPercent)),
            remainingPercent: min(100, max(0, 100 - source.usedPercent)),
            resetsAt: source.resetsAt
        )
    }

    // MARK: - Risk

    /// Lowest remaining percentage across every known window, or `nil` when no
    /// official quota has been read yet.
    public var minRemainingPercent: Double? {
        windows.map(\.remainingPercent).min()
    }

    /// The window that defines the current risk (the scarcest one).
    public var constrainingWindow: Window? {
        windows.min(by: { $0.remainingPercent < $1.remainingPercent })
    }

    public func riskLevel(at now: Date) -> RiskLevel {
        RiskLevel(
            minRemainingPercent: minRemainingPercent,
            projectedRunOut: paceAssessment(at: now) != nil
        )
    }

    public func pace(for window: Window, at now: Date) -> UsagePace? {
        UsagePace(
            window: QuotaWindow(
                usedPercent: window.usedPercent,
                windowMinutes: window.windowMinutes,
                resetsAt: window.resetsAt
            ),
            now: now
        )
    }

    /// The earliest projected depletion among windows that will not last until
    /// reset at the current average pace.
    public func paceAssessment(at now: Date) -> PaceAssessment? {
        windows
            .compactMap { window -> PaceAssessment? in
                guard let pace = pace(for: window, at: now),
                      !pace.willLastUntilReset,
                      pace.estimatedRunOutAt != nil
                else {
                    return nil
                }
                return PaceAssessment(window: window, pace: pace)
            }
            .min {
                ($0.pace.estimatedRunOutAt ?? .distantFuture)
                    < ($1.pace.estimatedRunOutAt ?? .distantFuture)
            }
    }

    /// True when no window is projected to run out before its reset.
    public func willLastUntilReset(at now: Date) -> Bool {
        paceAssessment(at: now) == nil
    }

    /// "☑ 可持续到重置" / "⚠ 预计 1 天 2 小时 后用尽" — the design's pace line.
    public func paceLine(at now: Date) -> String {
        guard let assessment = paceAssessment(at: now),
              let runOutAt = assessment.pace.estimatedRunOutAt
        else {
            return TRL10n.t("overview.pace.ok")
        }
        return TRL10n.f("overview.pace.runout", UsageFormatting.durationUntil(runOutAt, now: now))
    }

    /// The soonest upcoming reset among all windows that report one.
    public var soonestReset: Date? {
        windows.compactMap(\.resetsAt).min()
    }

    // MARK: - Today's token split (demo only)

    public var totalTokens: Int64? {
        guard let dailyTokens, !dailyTokens.isEmpty else { return nil }
        return dailyTokens.reduce(0) { $0 + $1.tokens }
    }

    public var totalCost: Double? {
        guard let dailyTokens, !dailyTokens.isEmpty else { return nil }
        return dailyTokens.reduce(0) { $0 + $1.estimatedCost }
    }

    // MARK: - Freshness

    /// Most recent capture time across every source in the snapshot.
    public var lastUpdated: Date? {
        [claude?.capturedAt, codex?.capturedAt].compactMap { $0 }.max()
    }
}
