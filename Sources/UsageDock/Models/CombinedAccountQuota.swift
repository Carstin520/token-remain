import Foundation

/// Presentation-only account units: each independently subscribed account is
/// 100%. Never encode this sum as a ProviderQuota (whose percentages are 0...100).
/// Matching plans are a necessary check, not proof of equal absolute capacity
/// or unique provider identity; the UI also requires explicit group consent.
struct CombinedAccountQuota: Sendable {
    struct Segment: Identifiable, Sendable {
        let id: ProviderAccountID
        let name: String
        let remaining: Double
        let resetsAt: Date?
    }

    struct Window: Identifiable, Sendable {
        let id: String
        let minutes: Int
        let name: String?
        let segments: [Segment]
        var remaining: Double { segments.reduce(0) { $0 + $1.remaining } }
        var capacity: Double { Double(segments.count) * 100 }
        var nextReset: Date? { segments.compactMap(\.resetsAt).min() }
        var nextRestored: Double {
            guard let nextReset else { return 0 }
            return segments.filter { $0.resetsAt == nextReset }.reduce(0) { $0 + 100 - $1.remaining }
        }
    }

    let plan: String
    let windows: [Window]
    let oldestReading: Date
    let consentFingerprint: String
    var accountCount: Int { windows.first?.segments.count ?? 0 }

    enum Unavailable: String, Error, Sendable {
        case accounts, readings, plans, windows
        var localizationKey: String { "accounts.combined.unavailable.\(rawValue)" }
    }

    static func evaluate(
        _ snapshots: [ProviderAccountSnapshot], now: Date = .now
    ) -> Result<Self, Unavailable> {
        // An unconfigured system placeholder has no subscription to add. An
        // unavailable managed login or a failing system login must not vanish.
        let enabled = snapshots.filter {
            $0.profile.isEnabled && !($0.profile.isSystem && $0.quota == nil
                && $0.notice == nil && !$0.isRefreshing)
        }
        guard enabled.count >= 2,
              Set(enabled.map(\.id)).count == enabled.count,
              Set(enabled.map(\.profile.provider)).count == 1 else { return .failure(.accounts) }
        guard enabled.allSatisfy({ $0.quota != nil && $0.notice == nil }) else {
            return .failure(.readings)
        }
        let quotas = enabled.compactMap(\.quota)
        let plans = quotas.map { $0.planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" }
        guard let plan = plans.first, !plan.isEmpty,
              !["unknown", "unknown plan", "max", "team", "enterprise"].contains(plan),
              plans.allSatisfy({ $0 == plan }) else { return .failure(.plans) }
        guard quotas.allSatisfy({ $0.provider == enabled[0].profile.provider
            && $0.attribution == nil && $0.accountBalance == nil && $0.remainingBalance == nil }) else {
            return .failure(.windows)
        }
        let rows = quotas.map(windowRows)
        let shape = rows[0].map(\.shape)
        guard rows.allSatisfy({ $0.map(\.shape) == shape
            && Set($0.map(\.id)).count == $0.count
            && $0.allSatisfy({ row in
                let w = row.window
                return w.usedPercent.isFinite && (0...100).contains(w.usedPercent)
                    && w.windowMinutes > 0 && w.remainingBalance == nil && w.remainingCredits == nil
                    && (w.resetsAt.map { $0 > now } ?? true)
            }) }) else { return .failure(.windows) }

        // Keep one account in the same segment across every window, ordered by
        // the earliest primary reset. Reset/usage/name updates don't revoke consent.
        let order = enabled.indices.sorted {
            let lhs = quotas[$0].primary.resetsAt ?? .distantFuture
            let rhs = quotas[$1].primary.resetsAt ?? .distantFuture
            return lhs == rhs ? enabled[$0].id.rawValue < enabled[$1].id.rawValue : lhs < rhs
        }
        let windows = rows[0].indices.map { index in
            let row = rows[0][index]
            return Window(id: row.id, minutes: row.window.windowMinutes, name: row.name,
                segments: order.map { account in
                    Segment(id: enabled[account].id, name: enabled[account].profile.accountDisplayName,
                            remaining: 100 - rows[account][index].window.usedPercent,
                            resetsAt: rows[account][index].window.resetsAt)
                })
        }
        let fingerprintParts = [enabled[0].profile.provider.rawValue, plan]
            + enabled.map(\.id.rawValue).sorted() + shape
        // JSON framing avoids ambiguous delimiters. Only opaque local IDs and
        // public plan/window labels enter this local preference; no credentials.
        guard let data = try? JSONEncoder().encode(fingerprintParts),
              let fingerprint = String(data: data, encoding: .utf8) else { return .failure(.windows) }
        return .success(Self(plan: quotas[0].planName ?? plan, windows: windows,
                             oldestReading: quotas.map(\.capturedAt).min() ?? now,
                             consentFingerprint: fingerprint))
    }

    private struct Row {
        let id: String
        let name: String?
        let window: QuotaWindow
        var shape: String { "\(id)|\(window.windowMinutes)|\(name ?? "")" }
    }

    private static func windowRows(_ quota: ProviderQuota) -> [Row] {
        var rows = [Row(id: "primary", name: quota.primary.poolName, window: quota.primary)]
        if let secondary = quota.secondary {
            rows.append(Row(id: "secondary", name: secondary.poolName, window: secondary))
        }
        rows += (quota.scopedWindows ?? []).sorted { $0.scopeID < $1.scopeID }.map {
            Row(id: "scoped:\($0.scopeID)", name: $0.displayName, window: $0.window)
        }
        return rows
    }
}
