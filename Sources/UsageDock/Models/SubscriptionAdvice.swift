import Foundation

/// Whether one subscription's tier fits how its account is actually used,
/// judged from the live quota windows and this Mac's quota history. It holds
/// structured evidence only; the cost card words it.
///
/// The thresholds prefer "not enough data" to a guess. Raising a tier needs
/// one clear sign of running out. Lowering one needs ten days of short-window
/// history plus a completed or mostly elapsed long window, and the busiest
/// window must still fit the cheaper tier with 20% to spare. Tier capacity
/// is the vendor's stated multiple (Max 20x = 20× Pro), so lowering advice is
/// an estimate, and tiers without a published multiple are never a target.
struct SubscriptionAdvice: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Nil target: the plan is unknown, or already the top tier.
        case upgrade(SubscriptionPlan?)
        case downgrade(SubscriptionPlan)
        case cancel
        case keep
        case insufficientData

        var isUpgrade: Bool {
            if case .upgrade = self { return true }
            return false
        }
    }

    enum Evidence: Sendable, Equatable {
        /// The current long window: `percent` is the projected end-of-window
        /// use when `isProjection`, otherwise what is used so far.
        case longWindow(windowMinutes: Int, percent: Double, isProjection: Bool)
        /// `ranOut` of the last `total` completed long windows reached the cap.
        case longWindowsRanOut(ranOut: Int, total: Int, windowMinutes: Int)
        /// Completed short windows that reached the cap within `days` days.
        case shortLimitHits(count: Int, days: Int, windowMinutes: Int)
        /// The highest use seen in a window of this length.
        case peak(windowMinutes: Int, percent: Double)
    }

    let kind: Kind
    let evidence: [Evidence]
    /// What the suggestion changes per month (target list price minus what
    /// the line costs now). Nil when either side is unknown.
    let monthlyDeltaUSD: Double?

    var isActionable: Bool {
        switch kind {
        case .upgrade, .downgrade, .cancel: true
        case .keep, .insufficientData: false
        }
    }

    static let insufficient = SubscriptionAdvice(kind: .insufficientData, evidence: [], monthlyDeltaUSD: nil)
}

/// The card's headline over every counted line.
struct SubscriptionAdviceSummary: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case changes(count: Int, netMonthlyDeltaUSD: Double)
        case allFit
        case insufficientData
    }

    let state: State

    init(_ advice: [SubscriptionAdvice]) {
        let actionable = advice.filter(\.isActionable)
        if !actionable.isEmpty {
            state = .changes(
                count: actionable.count,
                netMonthlyDeltaUSD: actionable.compactMap(\.monthlyDeltaUSD).reduce(0, +)
            )
        } else if advice.contains(where: { $0.kind == .keep }) {
            state = .allFit
        } else {
            state = .insufficientData
        }
    }
}

enum SubscriptionAdvisor {
    static let shortLookback: TimeInterval = 14 * 86_400
    /// A window that reached this share of its cap ran out.
    static let capPercent: Double = 95
    /// A cheaper tier must hold the busiest window at no more than this.
    static let downgradeCeiling: Double = 80
    /// Below this share of a long window elapsed, a linear projection is noise.
    static let minimumProjectionElapsed = 0.2
    static let minimumDowngradeDays = 10
    static let shortHitsPerWeek: Double = 3

    private struct Reading {
        let used: Double
        let windowMinutes: Int
        let resetsAt: Date?
        let capturedAt: Date
    }

    static func advise(
        line: SubscriptionCostLine,
        quota: ProviderQuota?,
        samples: [QuotaUsageHistory.Sample],
        now: Date = .now
    ) -> SubscriptionAdvice {
        guard let quota else { return .insufficient }
        let live = [quota.primary, quota.secondary].compactMap { $0 }
            .filter { $0.windowMinutes > 0 && $0.usedPercent.isFinite }
        let shortLive = live.filter { $0.windowMinutes < 1_440 }.min { $0.windowMinutes < $1.windowMinutes }
        let longLive = live.filter { $0.windowMinutes >= 1_440 }.max { $0.windowMinutes < $1.windowMinutes }

        let readings = samples.flatMap { sample -> [Reading] in
            var result = [Reading(
                used: sample.usedPercent,
                windowMinutes: sample.windowMinutes,
                resetsAt: sample.resetsAt,
                capturedAt: sample.capturedAt
            )]
            if let secondary = sample.secondary {
                result.append(Reading(
                    used: secondary.usedPercent,
                    windowMinutes: secondary.windowMinutes,
                    resetsAt: secondary.resetsAt,
                    capturedAt: sample.capturedAt
                ))
            }
            return result
        }

        // Short (five-hour) windows over the last fortnight.
        let shortCutoff = now.addingTimeInterval(-shortLookback)
        let shortReadings = shortLive.map { window in
            readings.filter { $0.windowMinutes == window.windowMinutes && $0.capturedAt >= shortCutoff }
        } ?? []
        let shortPeaks = completedPeaks(shortReadings, now: now)
        let observedDays = Set(shortReadings.map { Calendar.current.startOfDay(for: $0.capturedAt) }).count
        let shortHits = shortPeaks.filter { $0 >= capPercent }.count
        let shortMax = (shortPeaks + [shortLive?.usedPercent ?? 0]).max() ?? 0

        // Long (weekly or billing-month) windows across the whole history.
        // Billing months vary by a few days, so lengths match loosely.
        let longReadings = longLive.map { window in
            readings.filter {
                $0.windowMinutes >= 1_440 && abs($0.windowMinutes - window.windowMinutes) <= 3 * 1_440
            }
        } ?? []
        let longPeaks = Array(completedPeaks(longReadings, now: now).suffix(4))
        let longRanOut = longPeaks.filter { $0 >= capPercent }.count
        let elapsed = longLive.flatMap { elapsedFraction(of: $0, now: now) }
        let projected = longLive.flatMap { window in
            elapsed.flatMap { $0 >= minimumProjectionElapsed ? min(999, window.usedPercent / $0) : nil }
        }

        let tiers = SubscriptionPlanCatalog.plans(for: line.provider).sorted { $0.monthlyUSD < $1.monthlyUSD }
        let currentPlan = line.catalogPlan
        let currentUSD = line.monthlyUSD

        // Raise: any one clear sign of running out.
        var upgradeEvidence: [SubscriptionAdvice.Evidence] = []
        if let longLive {
            if let projected, projected >= 100 {
                upgradeEvidence.append(.longWindow(
                    windowMinutes: longLive.windowMinutes,
                    percent: projected,
                    isProjection: true
                ))
            } else if longLive.usedPercent >= capPercent {
                upgradeEvidence.append(.longWindow(
                    windowMinutes: longLive.windowMinutes,
                    percent: longLive.usedPercent,
                    isProjection: false
                ))
            }
            if longPeaks.count >= 2, longRanOut >= 2 {
                upgradeEvidence.append(.longWindowsRanOut(
                    ranOut: longRanOut,
                    total: longPeaks.count,
                    windowMinutes: longLive.windowMinutes
                ))
            }
        }
        if let shortLive, observedDays >= 3,
           Double(shortHits) * 7 / Double(observedDays) >= shortHitsPerWeek {
            upgradeEvidence.append(.shortLimitHits(
                count: shortHits,
                days: observedDays,
                windowMinutes: shortLive.windowMinutes
            ))
        }
        if !upgradeEvidence.isEmpty {
            let target = currentPlan.flatMap { plan in tiers.first { $0.monthlyUSD > plan.monthlyUSD } }
            return SubscriptionAdvice(
                kind: .upgrade(target),
                evidence: upgradeEvidence,
                monthlyDeltaUSD: target.flatMap { target in currentUSD.map { target.monthlyUSD - $0 } }
            )
        }

        // Lower or cancel: only with enough history on every window.
        let longEstimate = longLive.map { window in
            (elapsed ?? 0) >= 0.5 ? (projected ?? window.usedPercent) : window.usedPercent
        }
        let longMax = (longPeaks + [longEstimate].compactMap { $0 }).max()
        var peaks: [SubscriptionAdvice.Evidence] = []
        if let shortLive { peaks.append(.peak(windowMinutes: shortLive.windowMinutes, percent: shortMax)) }
        if let longLive, let longMax { peaks.append(.peak(windowMinutes: longLive.windowMinutes, percent: longMax)) }

        let shortEnough = shortLive == nil || observedDays >= minimumDowngradeDays
        let longEnough = longLive == nil || !longPeaks.isEmpty || (elapsed ?? 0) >= 0.5
        let hasAnyWindow = shortLive != nil || longLive != nil
        if hasAnyWindow, shortEnough, longEnough {
            let busiest = max(shortMax, longMax ?? 0)
            if busiest <= 2, let currentUSD, currentUSD > 0 {
                return SubscriptionAdvice(kind: .cancel, evidence: peaks, monthlyDeltaUSD: -currentUSD)
            }
            if let currentPlan, let capacity = currentPlan.relativeCapacity {
                let target = tiers.first { tier in
                    guard tier.monthlyUSD < currentPlan.monthlyUSD,
                          let tierCapacity = tier.relativeCapacity else { return false }
                    return busiest * capacity / tierCapacity <= downgradeCeiling
                }
                if let target {
                    return SubscriptionAdvice(
                        kind: .downgrade(target),
                        evidence: peaks,
                        monthlyDeltaUSD: currentUSD.map { target.monthlyUSD - $0 }
                    )
                }
            }
        }

        if observedDays >= 3 || longLive != nil {
            return SubscriptionAdvice(kind: .keep, evidence: peaks, monthlyDeltaUSD: nil)
        }
        return .insufficient
    }

    /// Peak use of each window that has already reset, oldest first. Readings
    /// of one window share a reset time; grouping on a half-hour grid absorbs
    /// the seconds of drift some providers report between refreshes.
    private static func completedPeaks(_ readings: [Reading], now: Date) -> [Double] {
        var peaks: [Int64: Double] = [:]
        for reading in readings {
            guard let resetsAt = reading.resetsAt, resetsAt <= now else { continue }
            let key = Int64((resetsAt.timeIntervalSince1970 / 1_800).rounded())
            peaks[key] = max(peaks[key] ?? 0, min(100, max(0, reading.used)))
        }
        return peaks.keys.sorted().compactMap { peaks[$0] }
    }

    private static func elapsedFraction(of window: QuotaWindow, now: Date) -> Double? {
        guard let resetsAt = window.resetsAt else { return nil }
        let duration = TimeInterval(window.windowMinutes) * 60
        let remaining = min(duration, max(0, resetsAt.timeIntervalSince(now)))
        return 1 - remaining / duration
    }
}
