import Foundation

/// Ported from `Support/UsageFormatting.swift`, with `L10n` replaced by `TRL10n`
/// and every `now` made an explicit parameter (no implicit `Date.now` in kit logic).
public enum UsageFormatting {
    public static func percent(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f%%", value)
            : String(format: "%.1f%%", value)
    }

    public static func compactNumber(_ value: Int64) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.2fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }

    public static func countdown(to date: Date, now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60

        if days > 0 { return TRL10n.f("duration.days_hours_minutes", days, hours, minutes) }
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Compact `HH:MM` countdown used by the design's hero countdown card.
    public static func shortCountdown(to date: Date, now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    /// Human reset label derived from a real reset date: a live countdown when
    /// the window resets within a day, otherwise an absolute weekday/date + time.
    public static func resetDescription(to date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return TRL10n.t("reset.in_progress") }
        if interval < 86_400 {
            return TRL10n.f("reset.countdown", countdown(to: date, now: now))
        }
        let style = interval < 7 * 86_400
            ? Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
            : Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        return TRL10n.f("reset.on", date.formatted(style.locale(TRL10n.locale)))
    }

    /// Absolute wall-clock label, e.g. "周五 13:00" — the design's card footers.
    public static func absoluteReset(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute().locale(TRL10n.locale)
        )
    }

    public static func durationUntil(_ date: Date, now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 { return TRL10n.f("duration.days_hours", days, hours) }
        if hours > 0 { return TRL10n.f("duration.hours_minutes", hours, minutes) }
        if minutes > 0 { return TRL10n.f("duration.minutes", minutes) }
        return TRL10n.t("duration.less_than_minute")
    }

    public static func freshnessDescription(since date: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(date))
        if age < 60 { return TRL10n.t("freshness.just_now") }
        if age < 3_600 { return TRL10n.f("freshness.minutes", Int(age / 60)) }
        if age < 86_400 { return TRL10n.f("freshness.hours", Int(age / 3_600)) }
        return TRL10n.f("freshness.days", Int(age / 86_400))
    }

    public static func windowName(minutes: Int) -> String {
        switch minutes {
        case 300: return TRL10n.f("duration.hours", 5)
        case 10_080: return TRL10n.f("duration.days", 7)
        default:
            if minutes % 1_440 == 0 { return TRL10n.f("duration.days", minutes / 1_440) }
            if minutes % 60 == 0 { return TRL10n.f("duration.hours", minutes / 60) }
            return TRL10n.f("duration.minutes", minutes)
        }
    }

    /// "Claude · 5 小时窗口"
    public static func windowTitle(provider: ProviderQuota.Provider, minutes: Int) -> String {
        "\(provider.shortName) · \(TRL10n.f("window.suffix", windowName(minutes: minutes)))"
    }
}
