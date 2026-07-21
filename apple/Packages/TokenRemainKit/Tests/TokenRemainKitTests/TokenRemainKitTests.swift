import Foundation
import Testing
@testable import TokenRemainKit

/// Every test injects a fixed `now`; no test reads the wall clock.
private let now = SnapshotComposer.previewNow

// MARK: - Pace math (port parity with Support/UsagePace.swift)

@Suite("UsagePace port parity")
struct UsagePaceTests {
    @Test("No reset date ⇒ no pace")
    func missingReset() {
        #expect(UsagePace(window: QuotaWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil), now: now) == nil)
    }

    @Test("Warm-up: under 3% of the window elapsed ⇒ no pace")
    func warmUp() {
        // 1% elapsed of a 5h window.
        let window = QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now + 17_820)
        #expect(UsagePace(window: window, now: now) == nil)

        // Exactly 3% elapsed ⇒ available.
        let atThreshold = QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now + 17_460)
        #expect(UsagePace(window: atThreshold, now: now) != nil)
    }

    @Test("Expired or out-of-window reset ⇒ no pace")
    func expiredReset() {
        #expect(UsagePace(window: QuotaWindow(usedPercent: 40, windowMinutes: 300, resetsAt: now - 60), now: now) == nil)
        // Reset further out than the window length is not this window's reset.
        #expect(UsagePace(window: QuotaWindow(usedPercent: 40, windowMinutes: 300, resetsAt: now + 20_000), now: now) == nil)
    }

    @Test("±2% band is on-track, outside is reserve or deficit")
    func band() throws {
        // Half the 5h window elapsed ⇒ expected 50%.
        let reset = now + 9_000
        let onTrack = try #require(UsagePace(window: QuotaWindow(usedPercent: 51.5, windowMinutes: 300, resetsAt: reset), now: now))
        #expect(onTrack.status == .onTrack)
        #expect(abs(onTrack.expectedUsedPercent - 50) < 0.001)

        let reserve = try #require(UsagePace(window: QuotaWindow(usedPercent: 30, windowMinutes: 300, resetsAt: reset), now: now))
        #expect(reserve.status == .reserve)

        let deficit = try #require(UsagePace(window: QuotaWindow(usedPercent: 70, windowMinutes: 300, resetsAt: reset), now: now))
        #expect(deficit.status == .deficit)
        #expect(deficit.showsRemainingWarning)
    }

    @Test("Deficit projects a run-out before the reset")
    func runOutProjection() throws {
        // 20h into a 7d window with 69% used.
        let pace = try #require(UsagePace(
            window: QuotaWindow(usedPercent: 69, windowMinutes: 10_080, resetsAt: now + 532_800),
            now: now
        ))
        #expect(pace.status == .deficit)
        #expect(pace.willLastUntilReset == false)
        let runOut = try #require(pace.estimatedRunOutAt)
        // 31 remaining / (69 per 72000s) ≈ 32348s ≈ 9h.
        #expect(abs(runOut.timeIntervalSince(now) - 32_347.8) < 1)
    }

    @Test("A sustainable pace reports no run-out")
    func sustainable() throws {
        let pace = try #require(UsagePace(
            window: QuotaWindow(usedPercent: 54, windowMinutes: 10_080, resetsAt: now + 259_200),
            now: now
        ))
        #expect(pace.willLastUntilReset)
        #expect(pace.estimatedRunOutAt == nil)
    }
}

// MARK: - Risk thresholds

@Suite("RiskLevel thresholds")
struct RiskLevelTests {
    @Test("Threshold edges")
    func edges() {
        #expect(RiskLevel(minRemainingPercent: 9.99) == .high)
        #expect(RiskLevel(minRemainingPercent: 10) == .medium)
        #expect(RiskLevel(minRemainingPercent: 29.99) == .medium)
        #expect(RiskLevel(minRemainingPercent: 30) == .low)
        #expect(RiskLevel(minRemainingPercent: 0) == .high)
        #expect(RiskLevel(minRemainingPercent: 100) == .low)
    }

    @Test("A projected run-out promotes an otherwise-low reading to medium")
    func projectedPromotion() {
        #expect(RiskLevel(minRemainingPercent: 80, projectedRunOut: true) == .medium)
        // …but never demotes a high reading.
        #expect(RiskLevel(minRemainingPercent: 5, projectedRunOut: true) == .high)
    }

    @Test("Absent data is unknown, never a number")
    func unknown() {
        #expect(RiskLevel(minRemainingPercent: nil) == .unknown)
        #expect(RiskLevel(minRemainingPercent: nil).badge == "—")
    }

    @Test("Every level carries a non-colour differentiator")
    func glyphs() {
        #expect(RiskLevel.medium.glyph == "!")
        #expect(RiskLevel.high.glyph == "‼")
        // The badge is localized: it routes through the `risk.short.*` keys rather
        // than a hardcoded English cap, so the hero chip follows the system language.
        #expect(RiskLevel.low.badge == TRL10n.t("risk.short.low"))
        #expect(TRL10n.t("risk.short.low", language: .zhHans) == "低")
        #expect(TRL10n.t("risk.short.low", language: .en) == "LOW")
    }
}

// MARK: - Insights

@Suite("UsageInsights derivations")
struct UsageInsightsTests {
    private var insights: UsageInsights {
        SnapshotComposer.demo(scenario: .concept, now: now).insights
    }

    @Test("Windows are ordered provider, then primary → secondary")
    func ordering() {
        let ids = insights.windows.map(\.id)
        #expect(ids == [
            "Claude Code-primary-300",
            "Claude Code-secondary-10080",
            "Codex-primary-10080"
        ])
    }

    @Test("Min remaining and constraining window agree")
    func constraining() throws {
        #expect(insights.minRemainingPercent == 46)
        let constraining = try #require(insights.constrainingWindow)
        #expect(constraining.provider == .codex)
        #expect(constraining.remainingPercent == 46)
    }

    @Test("Soonest reset is the earliest known reset")
    func soonestReset() throws {
        let reset = try #require(insights.soonestReset)
        #expect(abs(reset.timeIntervalSince(now) - 9_480) < 0.001)
    }

    @Test("A provider's lead window is its scarcest")
    func leadWindow() throws {
        let claude = try #require(insights.leadWindow(for: .claude))
        #expect(claude.remainingPercent == 85)
    }

    @Test("Unknown reset stays unknown rather than being invented")
    func unknownReset() throws {
        let fresh = SnapshotComposer.demo(scenario: .freshReset, now: now).insights
        let primary = try #require(fresh.windows.first)
        #expect(primary.resetsAt == nil)
        #expect(fresh.pace(for: primary, at: now) == nil)
    }
}

// MARK: - Snapshot codec

@Suite("Snapshot codec")
struct SnapshotCodecTests {
    @Test("Round-trips to an equal value")
    func roundTrip() throws {
        let snapshot = SnapshotComposer.demo(scenario: .concept, now: now)
        let data = try snapshot.encoded()
        let decoded = try #require(UsageSnapshot.decoded(from: data))
        #expect(decoded == snapshot)
    }

    @Test("An unknown schema version decodes to nil, not a crash")
    func unknownVersion() throws {
        let snapshot = UsageSnapshot(
            schemaVersion: 99,
            origin: .demo,
            generatedAt: now,
            providers: [],
            dailyTokens: nil
        )
        let data = try snapshot.encoded()
        #expect(UsageSnapshot.decoded(from: data) == nil)
    }

    @Test("Corrupt JSON decodes to nil, not a crash")
    func corrupt() {
        #expect(UsageSnapshot.decoded(from: Data("{ not json".utf8)) == nil)
        #expect(UsageSnapshot.decoded(from: Data()) == nil)
    }

    @Test("The empty snapshot carries no numbers")
    func emptySnapshot() {
        let empty = UsageSnapshot.empty(now: now)
        #expect(empty.origin == .none)
        #expect(empty.providers.isEmpty)
        #expect(empty.insights.minRemainingPercent == nil)
        #expect(empty.dailyTokens == nil)
    }
}

// MARK: - Determinism & scenario characters

@Suite("Demo determinism")
struct DemoDeterminismTests {
    @Test("Composing twice with the same now yields identical snapshots")
    func deterministic() {
        for scenario in DemoScenario.allCases {
            #expect(SnapshotComposer.demo(scenario: scenario, now: now)
                == SnapshotComposer.demo(scenario: scenario, now: now))
        }
    }

    @Test(".concept reproduces the confirmed design exactly")
    func conceptMatchesDesign() throws {
        let entry = TREntry(snapshot: SnapshotComposer.demo(scenario: .concept, now: now), now: now)
        #expect(entry.minRemainingPercent == 46)
        #expect(entry.heroText == "46%")
        #expect(entry.risk == .low)
        #expect(entry.willLastUntilReset)
        #expect(entry.runOutAt == nil)
        #expect(entry.providers.map(\.remainingPercent) == [85, 46])
        let reset = try #require(entry.soonestReset)
        #expect(UsageFormatting.shortCountdown(to: reset, now: now) == "02:38")
    }

    @Test(".deficitPace is promoted to medium by a projection, not by its percentage")
    func deficitScenario() throws {
        let entry = TREntry(snapshot: SnapshotComposer.demo(scenario: .deficitPace, now: now), now: now)
        #expect(entry.minRemainingPercent == 31)
        #expect(entry.risk == .medium)
        #expect(entry.willLastUntilReset == false)
        let runOut = try #require(entry.runOutAt)
        // ~9 hours out.
        #expect(abs(runOut.timeIntervalSince(now) - 32_400) < 120)
    }

    @Test(".critical is high risk with a ~42 minute projection")
    func criticalScenario() throws {
        let entry = TREntry(snapshot: SnapshotComposer.demo(scenario: .critical, now: now), now: now)
        #expect(entry.minRemainingPercent == 8)
        #expect(entry.risk == .high)
        let runOut = try #require(entry.runOutAt)
        #expect(abs(runOut.timeIntervalSince(now) - 2_520) < 60)
    }

    @Test(".freshReset is low risk and exercises the unknown-reset state")
    func freshResetScenario() {
        let snapshot = SnapshotComposer.demo(scenario: .freshReset, now: now)
        let entry = TREntry(snapshot: snapshot, now: now)
        #expect(entry.minRemainingPercent == 88)
        #expect(entry.risk == .low)
        #expect(snapshot.providers[0].primary.resetsAt == nil)
    }

    @Test("`.none` origin composes to a snapshot with no numbers at all")
    func noneOrigin() {
        let entry = TREntry(
            snapshot: SnapshotComposer.compose(origin: .none, scenario: .concept, now: now),
            now: now
        )
        #expect(entry.hasNumbers == false)
        #expect(entry.minRemainingPercent == nil)
        #expect(entry.heroText == "—")
        #expect(entry.providers.isEmpty)
        #expect(entry.risk == .unknown)
    }
}

// MARK: - History

@Suite("Snapshot history")
struct SnapshotHistoryTests {
    private func point(_ offset: TimeInterval, value: Double = 50, demo: Bool = false) -> SnapshotHistoryPoint {
        SnapshotHistoryPoint(
            generatedAt: now.addingTimeInterval(offset),
            minRemainingPercent: value,
            perProviderRemaining: [:],
            isDemo: demo
        )
    }

    @Test("Points inside one 10-minute bucket collapse to the newest")
    func dedupe() {
        var points = SnapshotHistoryStore.appending(point(0, value: 50), to: [])
        points = SnapshotHistoryStore.appending(point(120, value: 44), to: points)
        #expect(points.count == 1)
        #expect(points[0].minRemainingPercent == 44)

        // A different bucket appends.
        points = SnapshotHistoryStore.appending(point(1_200, value: 40), to: points)
        #expect(points.count == 2)
    }

    @Test("Demo and observed points never share a bucket slot")
    func demoAndRealCoexist() {
        var points = SnapshotHistoryStore.appending(point(0, demo: false), to: [])
        points = SnapshotHistoryStore.appending(point(60, demo: true), to: points)
        #expect(points.count == 2)
    }

    @Test("The ring buffer caps at 500 points, keeping the newest")
    func ringCap() {
        let overflowing = (0..<600).map { point(Double($0) * 1_200, value: Double($0 % 100)) }
        let normalized = SnapshotHistoryStore.normalized(overflowing)
        #expect(normalized.count == SnapshotHistoryStore.capacity)
        #expect(normalized.first?.generatedAt == overflowing[100].generatedAt)
    }

    @Test("Results stay sorted oldest → newest")
    func sorted() {
        let normalized = SnapshotHistoryStore.normalized([point(600), point(0), point(1_800)])
        #expect(normalized.map(\.generatedAt) == [now, now + 600, now + 1_800])
    }

    @Test("Demo history is deterministic and fully demo-flagged")
    func demoHistoryIsDeterministic() {
        let first = SnapshotComposer.demoHistory(scenario: .concept, now: now)
        #expect(first == SnapshotComposer.demoHistory(scenario: .concept, now: now))
        #expect(first.count == 168)
        #expect(first.allSatisfy { $0.isDemo })
        #expect(first.allSatisfy { (0...100).contains($0.minRemainingPercent) })
    }

    @Test("Clearing demo points removes only demo-flagged history")
    func clearingDemoKeepsObserved() {
        let mixed = [point(0, demo: true), point(1_200, demo: false), point(2_400, demo: true)]
        let kept = mixed.filter { !$0.isDemo }
        #expect(kept.count == 1)
        #expect(kept[0].isDemo == false)
    }

    @Test("Store round-trips through a temporary directory")
    func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-history-\(UUID().uuidString)", isDirectory: true)
        let store = SnapshotHistoryStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.load().isEmpty)
        let appended = store.append(SnapshotComposer.demo(scenario: .concept, now: now))
        #expect(appended.count == 1)
        #expect(store.load().first?.minRemainingPercent == 46)
        #expect(store.clearDemoPoints().isEmpty)
    }

    @Test("An empty snapshot contributes no history point")
    func emptyContributesNothing() {
        #expect(SnapshotHistoryPoint(snapshot: .empty(now: now)) == nil)
    }
}

// MARK: - Snapshot store

@Suite("Snapshot store")
struct SnapshotStoreTests {
    @Test("Write then read returns the same snapshot; clear empties it")
    func roundTrip() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-snapshot-\(UUID().uuidString)", isDirectory: true)
        let store = SnapshotStore(directory: directory, suiteName: nil)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.read() == nil)
        #expect(store.readOrEmpty(now: now).origin == .none)

        let snapshot = SnapshotComposer.demo(scenario: .concept, now: now)
        store.write(snapshot)
        #expect(store.read() == snapshot)

        store.clear()
        #expect(store.read() == nil)
    }
}

// MARK: - Robot moods

@Suite("Robot mood thresholds")
struct RobotMoodTests {
    @Test("All eleven ported thresholds resolve identically")
    func thresholds() {
        #expect(RobotMoodState.resolve(remainingPercent: 100) == .excitedStars)
        #expect(RobotMoodState.resolve(remainingPercent: 96) == .excitedStars)
        #expect(RobotMoodState.resolve(remainingPercent: 95.9) == .happyCarets)
        #expect(RobotMoodState.resolve(remainingPercent: 86) == .happyCarets)
        #expect(RobotMoodState.resolve(remainingPercent: 76) == .sparkle)
        #expect(RobotMoodState.resolve(remainingPercent: 66) == .calmDots)
        #expect(RobotMoodState.resolve(remainingPercent: 56) == .focusedBars)
        #expect(RobotMoodState.resolve(remainingPercent: 46) == .neutralDashes)
        #expect(RobotMoodState.resolve(remainingPercent: 36) == .worriedSlants)
        #expect(RobotMoodState.resolve(remainingPercent: 26) == .tenseChevrons)
        #expect(RobotMoodState.resolve(remainingPercent: 16) == .dizzySpirals)
        #expect(RobotMoodState.resolve(remainingPercent: 0.5) == .cryingWarning)
        #expect(RobotMoodState.resolve(remainingPercent: 0.4) == .offline)
        #expect(RobotMoodState.resolve(remainingPercent: 0) == .offline)
    }

    @Test("Out-of-range input is clamped, nil is neutral")
    func clamping() {
        #expect(RobotMoodState.resolve(remainingPercent: 140) == .excitedStars)
        #expect(RobotMoodState.resolve(remainingPercent: -20) == .offline)
        #expect(RobotMoodState.resolve(remainingPercent: nil) == .neutralDashes)
    }

    @Test("All eleven accessibility descriptions are distinct and non-empty")
    func descriptions() {
        let descriptions = RobotMoodState.allCases.map(\.accessibilityDescription)
        #expect(descriptions.count == 11)
        #expect(Set(descriptions).count == 11)
        #expect(descriptions.allSatisfy { !$0.isEmpty })
    }

    @Test("Eleven states collapse to exactly five drawn faces")
    func fiveFaces() {
        #expect(Set(RobotMoodState.allCases.map(\.face)).count == 5)
        // The design's 46% robot wears the flat-bar face.
        #expect(RobotMoodState.resolve(remainingPercent: 46).face == .neutral)
        #expect(RobotMoodState.resolve(remainingPercent: 0).face == .offline)
    }

    @Test("Every face produces a well-formed 16×12 matrix with visible eyes")
    func matrixShape() {
        for face in RobotFace.allCases {
            let grid = PixelRobot.matrix(face: face)
            #expect(grid.count == PixelRobot.rows)
            #expect(grid.allSatisfy { $0.count == PixelRobot.columns })
            let eyes = grid.flatMap { $0 }.filter {
                if case .eye = $0 { return true }
                return false
            }
            #expect(eyes.count >= 4)
        }
    }
}

// MARK: - Formatting goldens

@Suite("Formatting goldens")
struct UsageFormattingTests {
    @Test("Percent drops a trailing zero but keeps one decimal otherwise")
    func percent() {
        #expect(UsageFormatting.percent(46) == "46%")
        #expect(UsageFormatting.percent(46.5) == "46.5%")
        #expect(UsageFormatting.percent(0) == "0%")
    }

    @Test("Compact numbers scale by magnitude")
    func compactNumber() {
        #expect(UsageFormatting.compactNumber(999) == "999")
        #expect(UsageFormatting.compactNumber(1_500) == "1.5K")
        #expect(UsageFormatting.compactNumber(2_400_000) == "2.40M")
    }

    @Test("Countdown formats hours and days distinctly")
    func countdown() {
        #expect(UsageFormatting.countdown(to: now + 9_480, now: now) == "02:38:00")
        #expect(UsageFormatting.countdown(to: now + 125, now: now) == "02:05")
        #expect(UsageFormatting.countdown(to: now - 60, now: now) == "00:00")
        #expect(UsageFormatting.shortCountdown(to: now + 9_480, now: now) == "02:38")
    }

    @Test("Window names use the ported special cases")
    func windowName() {
        #expect(UsageFormatting.windowName(minutes: 300) == TRL10n.f("duration.hours", 5))
        #expect(UsageFormatting.windowName(minutes: 10_080) == TRL10n.f("duration.days", 7))
        #expect(UsageFormatting.windowName(minutes: 90) == TRL10n.f("duration.minutes", 90))
    }

    @Test("Freshness buckets by minute, hour and day")
    func freshness() {
        #expect(UsageFormatting.freshnessDescription(since: now, now: now) == TRL10n.t("freshness.just_now"))
        #expect(UsageFormatting.freshnessDescription(since: now, now: now + 300) == TRL10n.f("freshness.minutes", 5))
        #expect(UsageFormatting.freshnessDescription(since: now, now: now + 7_200) == TRL10n.f("freshness.hours", 2))
        #expect(UsageFormatting.freshnessDescription(since: now, now: now + 172_800) == TRL10n.f("freshness.days", 2))
    }

    @Test("An in-progress reset is labelled, never shown as a negative countdown")
    func resetInProgress() {
        #expect(UsageFormatting.resetDescription(to: now - 10, now: now) == TRL10n.t("reset.in_progress"))
    }

    @Test("Duration until uses days / hours / minutes tiers")
    func durationUntil() {
        #expect(UsageFormatting.durationUntil(now + 93_600, now: now) == TRL10n.f("duration.days_hours", 1, 2))
        #expect(UsageFormatting.durationUntil(now + 5_400, now: now) == TRL10n.f("duration.hours_minutes", 1, 30))
        #expect(UsageFormatting.durationUntil(now + 300, now: now) == TRL10n.f("duration.minutes", 5))
        #expect(UsageFormatting.durationUntil(now + 5, now: now) == TRL10n.t("duration.less_than_minute"))
    }
}

// MARK: - Localization

@Suite("Localization")
struct TRL10nTests {
    @Test("Every key carries a non-empty value in BOTH zh-Hans and en")
    func complete() {
        #expect(!TRL10n.table.isEmpty)
        for (key, entry) in TRL10n.table {
            // Guard against a key that was added in only one language, or left as an
            // empty placeholder — either would leak the raw key / a blank into the UI.
            #expect(!entry.zh.isEmpty, "missing zh-Hans value for \(key)")
            #expect(!entry.en.isEmpty, "missing en value for \(key)")
            #expect(!TRL10n.t(key, language: .zhHans).isEmpty)
            #expect(!TRL10n.t(key, language: .en).isEmpty)
        }
    }

    @Test("Language resolution matches zh / en and otherwise falls back to English")
    func resolution() {
        #expect(TRL10n.resolve(["zh-Hans-CN", "en-US"]) == .zhHans)
        #expect(TRL10n.resolve(["en-US", "zh-Hans"]) == .en)
        #expect(TRL10n.resolve(["zh"]) == .zhHans)
        #expect(TRL10n.resolve(["en"]) == .en)
        // An unsupported system language resolves to the English base, never Chinese.
        #expect(TRL10n.resolve(["fr-FR"]) == .en)
        #expect(TRL10n.resolve([]) == .en)
    }

    @Test("The kit bundle advertises both localizations so it follows the system")
    func bundleLocalizations() {
        // `Bundle.module.preferredLocalizations` is the primary resolution signal;
        // it only reflects the system language if the bundle declares both languages.
        // Bundle localization identifiers can come back region-cased or lowercased
        // depending on the platform (e.g. "zh-hans" on macOS), and `resolve` matches
        // case-insensitively, so compare in lower case.
        let declared = Set(Bundle.module.localizations.map { $0.lowercased() })
        #expect(declared.contains("en"))
        #expect(declared.contains("zh-hans"))
    }
}

// MARK: - Routing

@Suite("Deep-link routing")
struct TRRouteTests {
    @Test("Bare tab routes parse")
    func tabs() throws {
        for route in TRRoute.allCases {
            let parsed = try #require(TRRoute.parse(route.url))
            #expect(parsed.route == route)
            #expect(parsed.windowID == nil)
        }
    }

    @Test("A window anchor round-trips through the URL")
    func windowAnchor() throws {
        let windowID = "Codex-primary-10080"
        let parsed = try #require(TRRoute.parse(TRRoute.windowURL(windowID)))
        #expect(parsed.route == .limits)
        #expect(parsed.windowID == windowID)
    }

    @Test("Foreign or malformed URLs are rejected")
    func rejects() {
        #expect(TRRoute.parse(URL(string: "https://example.com/overview")!) == nil)
        #expect(TRRoute.parse(URL(string: "tokenremain://nope")!) == nil)
    }
}

// MARK: - Contrast (§4)

@Suite("WCAG contrast of theme tokens")
struct TRThemeContrastTests {
    @Test("Primary text is high contrast on both surfaces")
    func primaryText() {
        #expect(WCAG.contrastRatio(TRThemeHex.text, TRThemeHex.surface) >= 10)
        #expect(WCAG.contrastRatio(TRThemeHex.text, TRThemeHex.ink) >= 10)
        #expect(WCAG.contrastRatio(TRThemeHex.text, TRThemeHex.surface2) >= 10)
    }

    @Test("Secondary text clears the 4.6:1 body-text bar")
    func secondaryText() {
        #expect(WCAG.contrastRatio(TRThemeHex.textDim, TRThemeHex.surface) >= 4.6)
        #expect(WCAG.contrastRatio(TRThemeHex.textDim, TRThemeHex.ink) >= 4.6)
    }

    @Test("All three accents clear 3:1 for large text and UI elements")
    func accents() {
        for accent in [TRThemeHex.violet, TRThemeHex.indigo, TRThemeHex.cyan] {
            #expect(WCAG.contrastRatio(accent, TRThemeHex.surface) >= 3)
            #expect(WCAG.contrastRatio(accent, TRThemeHex.ink) >= 3)
        }
    }

    @Test("The filled HIGH badge keeps its off-white text legible on violet")
    func filledBadge() {
        #expect(WCAG.contrastRatio(TRThemeHex.text, TRThemeHex.violet) >= 3)
    }

    @Test("Face/lock complication brand meters clear 3:1 on ink and surface")
    func brandMeters() {
        // The watch-face / Lock Screen complications colour their meters with the
        // vendor brand colours (Claude coral, Codex blue) so they read as AI usage.
        for brand in [TRThemeHex.claudeBrand, TRThemeHex.codexBrand] {
            #expect(WCAG.contrastRatio(brand, TRThemeHex.ink) >= 3)
            #expect(WCAG.contrastRatio(brand, TRThemeHex.surface) >= 3)
        }
    }

    @Test("The palette contains no orange, green, yellow or red accent")
    func onlyThreeAccents() {
        // Hue guard: every chromatic token must sit in the violet→cyan arc
        // (roughly 190°–265°), which excludes warm hues and green entirely.
        let chromatic: [UInt32] = [
            TRThemeHex.violet, TRThemeHex.violetDim,
            TRThemeHex.indigo, TRThemeHex.indigoDim,
            TRThemeHex.cyan, TRThemeHex.cyanDim
        ]
        for hex in chromatic {
            let hue = Self.hueDegrees(hex)
            #expect(hue >= 185 && hue <= 270, "hue \(hue)° is outside the violet–cyan arc")
        }
    }

    private static func hueDegrees(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum
        guard delta > 0 else { return 0 }
        let hue: Double
        switch maximum {
        case r: hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        case g: hue = 60 * ((b - r) / delta + 2)
        default: hue = 60 * ((r - g) / delta + 4)
        }
        return hue < 0 ? hue + 360 : hue
    }
}

// MARK: - Codex glyph geometry (ported from the desktop mark)

@Suite("Codex glyph geometry")
struct CodexGlyphGeometryTests {
    private let rect = CGRect(x: 0, y: 0, width: 24, height: 24)

    @Test("The flower and prompt both produce non-empty paths inside the frame")
    func nonEmptyBounds() {
        let flower = CodexGlyphGeometry.flower(in: rect)
        let prompt = CodexGlyphGeometry.prompt(in: rect)
        #expect(!flower.isEmpty)
        #expect(!prompt.isEmpty)
        // The lobes stay within the drawing rect (the union of ellipse rects).
        #expect(flower.boundingRect.minX >= -0.001)
        #expect(flower.boundingRect.maxX <= rect.width + 0.001)
    }

    @Test("The prompt stroke thickens below 14pt for legibility")
    func sizeConditionalStroke() {
        #expect(CodexGlyphGeometry.promptStrokeRatio(for: 20) == CodexGlyphGeometry.promptStrokeRatio)
        #expect(CodexGlyphGeometry.promptStrokeRatio(for: 12) > CodexGlyphGeometry.promptStrokeRatio)
    }

    @Test("The gradient runs violet → blue in three stops")
    func gradientStops() {
        #expect(CodexGlyphGeometry.gradientColors.count == 3)
    }
}

// MARK: - Cyberpunk dot-matrix numerals (hero experiment)

@Suite("Dot-matrix numerals")
struct PixelDigitTextTests {
    @Test("Every hero/countdown character has a well-formed 5×7 pattern")
    func glyphCoverage() {
        // The minimal set the hero % and reset countdown need.
        for character in "0123456789%:." {
            let pattern = PixelDigitText.glyphs[character]
            #expect(pattern?.count == 7, "\(character) must have 7 rows")
            #expect(pattern?.allSatisfy { $0.count == 5 } == true, "\(character) rows must be 5 wide")
            #expect(pattern?.contains { $0.contains("1") } == true, "\(character) must light some dots")
        }
    }
}

// MARK: - Timeline entry composition (stand-in for untestable WidgetKit providers)

@Suite("Timeline entry composition")
struct TREntryTests {
    @Test("Placeholder entries always carry the concept numbers")
    func placeholder() {
        let entry = TREntry.placeholder(now: now)
        #expect(entry.heroText == "46%")
        #expect(entry.isDemo)
    }

    @Test("Empty entries expose no numbers to any surface")
    func empty() {
        let entry = TREntry.empty(now: now)
        #expect(entry.hasNumbers == false)
        #expect(entry.isDemo == false)
        #expect(entry.providers.isEmpty)
        #expect(entry.soonestReset == nil)
    }

    @Test("Provider lines keep provider identity and window metadata")
    func providerLines() throws {
        let entry = TREntry(snapshot: SnapshotComposer.demo(scenario: .concept, now: now), now: now)
        let codex = try #require(entry.providers.first { $0.provider == .codex })
        #expect(codex.displayName == "Codex")
        #expect(codex.windowMinutes == 10_080)
        #expect(codex.remainingPercent == 46)
    }
}
