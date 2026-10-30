import CryptoKit
import Foundation

/// Per-model usage is optional detail that changes slowly, while relay sites
/// rate-limit their log endpoints per IP — new-api's critical limiter shares
/// one budget with the balance request, so polling it every refresh could
/// start failing the balance itself. Each source is fetched at most once per
/// `interval`. A failed fetch keeps the last good value (display-only data)
/// and still waits out the interval, so a key without access is not retried
/// on every refresh. In memory only; keys are SHA-256 digests, never secrets.
actor ModelUsageThrottle {
    struct Value: Sendable, Equatable {
        let usage: [ProviderModelUsage]?
        let period: ModelUsagePeriod?

        static let unavailable = Value(usage: nil, period: nil)
    }

    private struct Entry {
        let checkedAt: Date
        let value: Value
    }

    static let shared = ModelUsageThrottle()
    static let interval: TimeInterval = 15 * 60

    private var entries: [String: Entry] = [:]

    static func key(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func value(
        for key: String,
        now: Date = .now,
        fetch: @Sendable () async -> Value
    ) async -> Value {
        if let entry = entries[key], now.timeIntervalSince(entry.checkedAt) < Self.interval {
            return entry.value
        }
        let fetched = await fetch()
        let kept = fetched.usage == nil ? (entries[key]?.value ?? fetched) : fetched
        entries[key] = Entry(checkedAt: now, value: kept)
        return kept
    }
}
