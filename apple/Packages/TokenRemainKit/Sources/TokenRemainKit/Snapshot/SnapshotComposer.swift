import Foundation

/// Deterministic demo scenarios. Windows are built as **fixed offsets from `now`**,
/// so countdowns look live while the data stays reproducible for any injected `now`.
public enum DemoScenario: String, CaseIterable, Codable, Sendable, Identifiable {
    case concept
    case deficitPace
    case critical
    case freshReset

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .concept: return TRL10n.current == .zhHans ? "设计稿" : "Concept"
        case .deficitPace: return TRL10n.current == .zhHans ? "超预算节奏" : "Deficit pace"
        case .critical: return TRL10n.current == .zhHans ? "额度告急" : "Critical"
        case .freshReset: return TRL10n.current == .zhHans ? "刚刚重置" : "Fresh reset"
        }
    }
}

public enum SnapshotComposer {
    /// The single fixed instant used by every preview and test.
    public static let previewNow = Date(timeIntervalSinceReferenceDate: 790_000_000)

    public static func compose(origin: SnapshotOrigin, scenario: DemoScenario, now: Date) -> UsageSnapshot {
        switch origin {
        case .none: return .empty(now: now)
        case .demo: return demo(scenario: scenario, now: now)
        }
    }

    /// Deterministic fixture generator. Given the same `scenario` and `now` this is
    /// byte-for-byte reproducible.
    public static func demo(scenario: DemoScenario, now: Date) -> UsageSnapshot {
        let claude: ProviderQuota
        let codex: ProviderQuota

        switch scenario {
        case .concept:
            // Matches the confirmed design: min 46%, LOW, 可持续到重置,
            // soonest reset now+2h38m.
            claude = ProviderQuota(
                provider: .claude,
                primary: QuotaWindow(usedPercent: 8, windowMinutes: 300, resetsAt: now + 9_480),
                secondary: QuotaWindow(usedPercent: 15, windowMinutes: 10_080, resetsAt: now + 345_600),
                planName: "Max",
                capturedAt: now
            )
            codex = ProviderQuota(
                provider: .codex,
                primary: QuotaWindow(usedPercent: 54, windowMinutes: 10_080, resetsAt: now + 259_200),
                secondary: nil,
                planName: "Pro",
                capturedAt: now
            )

        case .deficitPace:
            // Codex is over budget: projected to run out ~9h from now, well before
            // its reset. Risk is promoted to MEDIUM by the projection, not by the
            // remaining percentage (31%).
            claude = ProviderQuota(
                provider: .claude,
                primary: QuotaWindow(usedPercent: 22, windowMinutes: 300, resetsAt: now + 3_600),
                secondary: QuotaWindow(usedPercent: 38, windowMinutes: 10_080, resetsAt: now + 302_400),
                planName: "Max",
                capturedAt: now
            )
            codex = ProviderQuota(
                provider: .codex,
                primary: QuotaWindow(usedPercent: 69, windowMinutes: 10_080, resetsAt: now + 532_800),
                secondary: nil,
                planName: "Pro",
                capturedAt: now
            )

        case .critical:
            // Claude's 5h window is nearly empty (8% remaining ⇒ HIGH), and Codex is
            // projected to run out ~42 min from now.
            claude = ProviderQuota(
                provider: .claude,
                primary: QuotaWindow(usedPercent: 92, windowMinutes: 300, resetsAt: now + 1_000),
                secondary: QuotaWindow(usedPercent: 45, windowMinutes: 10_080, resetsAt: now + 302_400),
                planName: "Max",
                capturedAt: now
            )
            codex = ProviderQuota(
                provider: .codex,
                primary: QuotaWindow(usedPercent: 88, windowMinutes: 10_080, resetsAt: now + 586_320),
                secondary: nil,
                planName: "Pro",
                capturedAt: now
            )

        case .freshReset:
            // Claude's 5h window just reset and the provider has not yet reported the
            // next reset time. That "unknown" stays unknown — it is never faked.
            claude = ProviderQuota(
                provider: .claude,
                primary: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil),
                secondary: QuotaWindow(usedPercent: 3, windowMinutes: 10_080, resetsAt: now + 544_320),
                planName: "Max",
                capturedAt: now
            )
            codex = ProviderQuota(
                provider: .codex,
                primary: QuotaWindow(usedPercent: 12, windowMinutes: 10_080, resetsAt: now + 504_000),
                secondary: nil,
                planName: "Pro",
                capturedAt: now
            )
        }

        return UsageSnapshot(
            origin: .demo,
            generatedAt: now,
            providers: [claude, codex],
            dailyTokens: demoTokens(scenario: scenario)
        )
    }

    private static func demoTokens(scenario: DemoScenario) -> [AgentTokens] {
        switch scenario {
        case .concept:
            return [
                AgentTokens(id: "claude", tokens: 4_820_000, estimatedCost: 12.40),
                AgentTokens(id: "codex", tokens: 2_150_000, estimatedCost: 5.05)
            ]
        case .deficitPace:
            return [
                AgentTokens(id: "claude", tokens: 6_100_000, estimatedCost: 15.80),
                AgentTokens(id: "codex", tokens: 8_940_000, estimatedCost: 21.10)
            ]
        case .critical:
            return [
                AgentTokens(id: "claude", tokens: 11_300_000, estimatedCost: 29.60),
                AgentTokens(id: "codex", tokens: 9_700_000, estimatedCost: 23.20)
            ]
        case .freshReset:
            return [
                AgentTokens(id: "claude", tokens: 120_000, estimatedCost: 0.31),
                AgentTokens(id: "codex", tokens: 480_000, estimatedCost: 1.12)
            ]
        }
    }

    /// Deterministic 7-day history seeded when demo mode turns on. Flagged demo so
    /// it can be removed wholesale when demo mode turns off — no demo residue is
    /// ever presented as real observation.
    public static func demoHistory(scenario: DemoScenario, now: Date) -> [SnapshotHistoryPoint] {
        let snapshot = demo(scenario: scenario, now: now)
        let base = snapshot.insights.minRemainingPercent ?? 50
        return (0..<168).map { index in
            let hoursAgo = Double(167 - index)
            let at = now.addingTimeInterval(-hoursAgo * 3_600)
            // Deterministic wave, no randomness.
            let wave = sin(Double(index) / 168.0 * .pi * 4) * 12
            let drift = (Double(index) / 168.0) * -8
            let value = min(100, max(0, base + 14 + wave + drift))
            return SnapshotHistoryPoint(
                generatedAt: at,
                minRemainingPercent: value,
                perProviderRemaining: [
                    ProviderQuota.Provider.claude.rawValue: min(100, value + 30),
                    ProviderQuota.Provider.codex.rawValue: value
                ],
                isDemo: true
            )
        }
    }
}
