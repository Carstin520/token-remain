import Foundation

enum UsageFormatting {
    static func percent(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f%%", value)
            : String(format: "%.1f%%", value)
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

        if days > 0 { return "\(days)天 \(hours)小时 \(minutes)分" }
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Human reset label derived from a real reset date: a live countdown when
    /// the window resets within a day, otherwise an absolute weekday/date + time.
    static func resetDescription(to date: Date, now: Date = .now) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "正在重置" }
        if interval < 86_400 {
            return "重置还有 " + countdown(to: date, now: now)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = interval < 7 * 86_400 ? "EEE HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date) + " 重置"
    }

    static func windowName(minutes: Int) -> String {
        switch minutes {
        case 300: return "5 小时"
        case 10_080: return "7 天"
        default:
            if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天" }
            if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
            return "\(minutes) 分钟"
        }
    }
}
