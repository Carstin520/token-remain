import Foundation

enum UsageFormatting {
    static func percent(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f%%", value)
            : String(format: "%.1f%%", value)
    }

    /// OpenUsage 式紧凑美元:千元以下保留两位小数($118.90),
    /// 千元以上收缩为 $2.5K / $1.2M,消费瓦片一眼可比。
    static func compactUSD(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "$%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "$%.1fK", value / 1_000) }
        return String(format: "$%.2f", value)
    }

    static func compactNumber(_ value: Int64) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.2fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }

    static func countdown(to date: Date, now: Date = .now) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60

        if days > 0 { return L10n.format("duration.days_hours_minutes", days, hours, minutes) }
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Human reset label derived from a real reset date: a live countdown when
    /// the window resets within a day, otherwise an absolute weekday/date + time.
    static func resetDescription(to date: Date, now: Date = .now) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return L10n.text("reset.in_progress") }
        if interval < 86_400 {
            return L10n.format("reset.countdown", countdown(to: date, now: now))
        }
        let style = interval < 7 * 86_400
            ? Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
            : Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        return L10n.format("reset.on", date.formatted(style.locale(.current)))
    }

    static func durationUntil(_ date: Date, now: Date = .now) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 { return L10n.format("duration.days_hours", days, hours) }
        if hours > 0 { return L10n.format("duration.hours_minutes", hours, minutes) }
        if minutes > 0 { return L10n.format("duration.minutes", minutes) }
        return L10n.text("duration.less_than_minute")
    }

    static func freshnessDescription(since date: Date, now: Date = .now) -> String {
        let age = max(0, now.timeIntervalSince(date))
        if age < 60 { return L10n.text("freshness.just_now") }
        if age < 3_600 { return L10n.format("freshness.minutes", Int(age / 60)) }
        if age < 86_400 { return L10n.format("freshness.hours", Int(age / 3_600)) }
        return L10n.format("freshness.days", Int(age / 86_400))
    }

    static func windowName(minutes: Int) -> String {
        switch minutes {
        // 0 哨兵 = 无滚动窗口的累计额度(如 OpenRouter 预充积分)。
        case ...0: return L10n.text("duration.total")
        case 300: return L10n.format("duration.hours", 5)
        case 10_080: return L10n.format("duration.days", 7)
        default:
            if minutes % 1_440 == 0 { return L10n.format("duration.days", minutes / 1_440) }
            if minutes % 60 == 0 { return L10n.format("duration.hours", minutes / 60) }
            return L10n.format("duration.minutes", minutes)
        }
    }
}
