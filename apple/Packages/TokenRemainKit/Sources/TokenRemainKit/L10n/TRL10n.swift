import Foundation

/// Minimal two-language catalogue (zh-Hans primary, en fallback).
///
/// Deliberately a plain Swift table rather than a `.xcstrings` resource: the kit is
/// linked into two widget extensions and a watch app, and a resource-bundle-free
/// kit removes an entire class of extension bundle-lookup failures. Lookup is pure
/// and injectable, so goldens are testable without swizzling `Locale`.
public enum TRL10n {
    public enum Language: String, Sendable { case zhHans, en }

    /// The UI language, resolved once per process from the system.
    ///
    /// Resolution follows the system language automatically: `-AppleLanguages` launch
    /// overrides, the per-app language (Settings › Token Remain › Language) and the
    /// device language all flow through the two signals scanned by `resolve`, so the
    /// whole interface switches with the system without any in-app language control.
    public static let current: Language = resolve()

    /// The `Locale` that matches the resolved UI language, so dates (weekday names,
    /// month names) render in the same language as the rest of the interface rather
    /// than following the device region. Without this, a zh-Hans UI on an en device
    /// would render "Fri" instead of "周五". Keyed off the same `current` resolution
    /// as every string, so a language and its dates never disagree.
    public static var locale: Locale {
        switch current {
        case .zhHans: return Locale(identifier: "zh_Hans")
        case .en: return Locale(identifier: "en")
        }
    }

    /// Resolves the UI language from the system.
    ///
    /// The primary signal is `Locale.preferredLanguages` — the user's ordered language
    /// preference, which honours the device language, the per-app language override
    /// (Settings › Token Remain › Language) and the `-AppleLanguages` launch argument
    /// alike. `Bundle.module.preferredLocalizations` (the kit bundle's own `en` +
    /// `zh-Hans`, intersected with the user's languages) follows as a corroborating
    /// fallback. Both are per-process, so a widget or watch extension resolves in
    /// exactly the language its host process was launched in.
    ///
    /// Unmatched system languages fall back to English (the kit's base localization)
    /// rather than defaulting to Chinese. `preferred` is injectable for tests.
    static func resolve(
        _ preferred: [String] = Locale.preferredLanguages + Bundle.module.preferredLocalizations
    ) -> Language {
        for code in preferred {
            let lower = code.lowercased()
            if lower.hasPrefix("zh") { return .zhHans }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }

    public static func t(_ key: String) -> String { t(key, language: current) }

    public static func t(_ key: String, language: Language) -> String {
        guard let entry = table[key] else {
            assertionFailure("missing TRL10n key: \(key)")
            return key
        }
        switch language {
        case .zhHans: return entry.zh
        case .en: return entry.en
        }
    }

    public static func f(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    public static func f(_ key: String, language: Language, _ arguments: any CVarArg...) -> String {
        String(format: t(key, language: language), arguments: arguments)
    }

    struct Entry: Sendable {
        let zh: String
        let en: String
        init(_ zh: String, _ en: String) {
            self.zh = zh
            self.en = en
        }
    }

    static let table: [String: Entry] = [
        // Durations & freshness
        "duration.days_hours_minutes": Entry("%1$d 天 %2$d 小时 %3$d 分", "%1$dd %2$dh %3$dm"),
        "duration.days_hours": Entry("%1$d 天 %2$d 小时", "%1$dd %2$dh"),
        "duration.hours_minutes": Entry("%1$d 小时 %2$d 分", "%1$dh %2$dm"),
        "duration.minutes": Entry("%d 分钟", "%d min"),
        "duration.hours": Entry("%d 小时", "%d hours"),
        "duration.days": Entry("%d 天", "%d days"),
        "duration.less_than_minute": Entry("不到 1 分钟", "under a minute"),
        "freshness.just_now": Entry("刚刚", "just now"),
        "freshness.minutes": Entry("%d 分钟前", "%d min ago"),
        "freshness.hours": Entry("%d 小时前", "%d h ago"),
        "freshness.days": Entry("%d 天前", "%d d ago"),
        "reset.in_progress": Entry("正在重置", "resetting"),
        "reset.countdown": Entry("重置还有 %@", "resets in %@"),
        "reset.on": Entry("%@ 重置", "resets %@"),
        "window.suffix": Entry("%@窗口", "%@ window"),

        // Risk
        "risk.headline.low": Entry("额度充足", "Plenty of quota"),
        "risk.headline.medium": Entry("额度偏紧", "Quota running tight"),
        "risk.headline.high": Entry("额度即将耗尽", "Quota nearly exhausted"),
        "risk.headline.unknown": Entry("暂无额度数据", "No quota data"),
        "risk.summary.low": Entry("当前节奏可以持续到重置。", "Current pace lasts until reset."),
        "risk.summary.medium": Entry("剩余额度有限，注意节奏。", "Limited quota left — watch your pace."),
        "risk.summary.high": Entry("剩余额度很低，建议暂缓高消耗任务。", "Very little quota left; hold off on heavy tasks."),
        "risk.summary.unknown": Entry("尚未读取到官方额度。", "No official quota has been read yet."),

        // Provenance / honesty
        "origin.none.title": Entry("未连接数据源", "No data source connected"),
        "origin.none.body": Entry(
            "iPhone 上没有 Claude Code 或 Codex 的本地额度来源。真实数据需要一个 Mac 伴侣同步或服务端来源 —— 两者都未随本版本发布。你可以在「设置」中打开演示模式，查看带明确标注的示例数据。",
            "There is no local Claude Code or Codex quota source on iPhone. Real data would require a Mac companion sync or a server source — neither ships in this build. Turn on Demo Mode in Settings to see clearly-labelled sample data."
        ),
        "origin.demo.status": Entry("全部数据源正常", "All sources nominal"),
        "origin.none.status": Entry("未连接数据源", "No data source"),
        "demo.chip": Entry("演示", "DEMO"),
        "demo.a11y": Entry("演示数据", "Demo data"),
        "privacy.statement": Entry(
            "Token Remain 不联网、不存储任何凭证。",
            "Token Remain never connects to the network and stores no credentials."
        ),

        // Tabs
        "tab.overview": Entry("概览", "Overview"),
        "tab.limits": Entry("额度", "Limits"),
        "tab.trends": Entry("趋势", "Trends"),
        "tab.settings": Entry("设置", "Settings"),

        // Overview
        "overview.risk.caption": Entry("当前额度风险", "Current quota risk"),
        "overview.min_remaining": Entry("最低剩余", "Lowest remaining"),
        "overview.pace.ok": Entry("可持续到重置", "Lasts until reset"),
        "overview.pace.runout": Entry("预计 %@ 后用尽", "Runs out in %@"),
        "overview.reset.card": Entry("重置还有", "Resets in"),
        "overview.trend.card": Entry("7 天趋势", "7-day trend"),
        "overview.trend.empty": Entry("暂无本机历史", "No on-device history yet"),
        "overview.cta": Entry("查看最紧张窗口", "View tightest window"),

        // Limits
        "limits.pace.expected": Entry("预算用量", "Budgeted use"),
        "limits.pace.actual": Entry("实际用量", "Actual use"),
        "limits.pace.delta": Entry("偏差", "Delta"),
        "limits.pace.status.ontrack": Entry("按预算", "On budget"),
        "limits.pace.status.reserve": Entry("有盈余", "In reserve"),
        "limits.pace.status.deficit": Entry("超预算", "Over budget"),
        "limits.pace.projected": Entry("按当前节奏预计 %@ 后用尽", "At the current pace, projected to run out in %@"),
        "limits.pace.unavailable": Entry("窗口刚开始，暂不预测节奏", "Window just started — no pace estimate yet"),
        "limits.reset.section": Entry("官方重置时间", "Official reset time"),
        "limits.reset.unknown": Entry("重置时间未知", "Reset time unknown"),
        "limits.empty": Entry("没有可显示的额度窗口。", "No quota windows to show."),

        // Trends
        "trends.title.min": Entry("最低剩余（按天）", "Lowest remaining (daily)"),
        "trends.title.provider": Entry("各数据源剩余", "Remaining by source"),
        "trends.meta.points": Entry("记录点数 %d", "%d recorded points"),
        "trends.meta.earliest": Entry("最早记录 %@", "Earliest record %@"),
        "trends.empty": Entry(
            "iPhone 端没有独立数据源，趋势只记录本机看到过的快照。",
            "iPhone has no independent data source; trends only record snapshots this device has actually seen."
        ),

        // Settings
        "settings.section.source": Entry("数据源", "Data source"),
        "settings.origin.row": Entry("当前来源", "Current origin"),
        "settings.demo.toggle": Entry("演示模式", "Demo Mode"),
        "settings.demo.footer": Entry(
            "演示模式使用确定性示例数据，所有界面都会显示「演示」标记。关闭后，小组件、实时活动与手表都会回到「未连接」状态。",
            "Demo Mode uses deterministic sample data and marks every surface as DEMO. Turning it off returns widgets, Live Activity and the watch to the not-connected state."
        ),
        "settings.scenario": Entry("演示场景", "Demo scenario"),
        "settings.section.liveactivity": Entry("实时活动", "Live Activity"),
        "settings.liveactivity.start": Entry("开始实时活动", "Start Live Activity"),
        "settings.liveactivity.stop": Entry("停止实时活动", "Stop Live Activity"),
        "settings.liveactivity.active": Entry("运行中", "Running"),
        "settings.liveactivity.inactive": Entry("未运行", "Not running"),
        "settings.liveactivity.denied": Entry("系统已关闭实时活动权限，请在「设置 › Token Remain」中开启。", "Live Activities are disabled for this app in iOS Settings."),
        "settings.liveactivity.needsdemo": Entry("实时活动只显示演示数据，请先打开演示模式。", "Live Activity only shows demo data — turn on Demo Mode first."),
        "settings.section.widgets": Entry("小组件", "Widgets"),
        "settings.widgets.home": Entry("长按主屏幕空白处 › 编辑 › 添加小组件 › Token Remain", "Touch and hold the Home Screen › Edit › Add Widget › Token Remain"),
        "settings.widgets.lock": Entry("锁定屏幕 › 自定义 › 添加小组件 › Token Remain", "Lock Screen › Customize › Add Widgets › Token Remain"),
        "settings.widgets.control": Entry("设置 › 操作按钮 › 控制 › 刷新额度", "Settings › Action Button › Controls › Refresh quota"),
        "settings.section.watch": Entry("Apple Watch", "Apple Watch"),
        "settings.watch.paired": Entry("已配对", "Paired"),
        "settings.watch.notpaired": Entry("未配对", "Not paired"),
        "settings.watch.installed": Entry("已安装手表 App", "Watch app installed"),
        "settings.watch.notinstalled": Entry("未安装手表 App", "Watch app not installed"),
        "settings.watch.lastsync": Entry("上次同步 %@", "Last sync %@"),
        "settings.watch.neversync": Entry("尚未同步", "Never synced"),
        "settings.watch.unsupported": Entry("此设备不支持 WatchConnectivity", "WatchConnectivity is unavailable on this device"),
        "settings.section.about": Entry("关于", "About"),
        "settings.version": Entry("版本", "Version"),

        // Intents / control
        "intent.refresh.title": Entry("刷新额度", "Refresh quota"),
        "intent.refresh.done": Entry("已刷新 · 最低 %@", "Refreshed · lowest %@"),
        "intent.refresh.none": Entry("未连接数据源", "No data source connected"),
        "intent.open.title": Entry("查看 Token Remain", "Open Token Remain"),
        "intent.startla.title": Entry("开始实时活动", "Start Live Activity"),
        "intent.stopla.title": Entry("停止实时活动", "Stop Live Activity"),
        "intent.startla.done": Entry("实时活动已开始", "Live Activity started"),
        "intent.stopla.done": Entry("实时活动已停止", "Live Activity stopped"),

        // Live Activity
        "liveactivity.stale": Entry("数据未更新", "Data not updated"),
        "liveactivity.refresh": Entry("刷新", "Refresh"),

        // Risk — short caps for dense surfaces (watch / complications)
        "risk.short.low": Entry("低", "LOW"),
        "risk.short.medium": Entry("中", "MED"),
        "risk.short.high": Entry("高", "HIGH"),
        "risk.short.unknown": Entry("—", "—"),

        // Pace — compact judgement line
        "pace.short.ok": Entry("可持续到重置", "Lasts until reset"),
        "pace.short.early": Entry("可能提前用尽", "May run out early"),

        // Today's usage (watch page 4)
        "today.title": Entry("今日用量", "Today's usage"),
        "today.tokens": Entry("Tokens", "Tokens"),
        "today.cost": Entry("估算成本", "Est. cost"),
        "today.empty": Entry("暂无本地统计", "No local usage yet"),
        "today.source.demo": Entry("演示 · 数据留在本机", "Demo · data stays on device"),

        // Watch
        "watch.provenance": Entry("来自 iPhone · %@", "From iPhone · %@"),
        "watch.plan": Entry("套餐 %@", "%@ plan"),
        "watch.page.overview": Entry("概览", "Overview"),
        "watch.waiting": Entry("等待 iPhone 同步", "Waiting for iPhone sync"),
        "watch.waiting.body": Entry("在 iPhone 上打开 Token Remain 即可同步最新快照。", "Open Token Remain on iPhone to sync the latest snapshot."),

        // Robot moods (ported descriptions)
        "robot.100": Entry("额度充足，兴奋", "Plenty of quota — excited"),
        "robot.90": Entry("额度充足，开心", "Plenty of quota — happy"),
        "robot.80": Entry("额度健康，精神", "Healthy quota — bright"),
        "robot.70": Entry("额度健康，平稳", "Healthy quota — calm"),
        "robot.60": Entry("额度适中，专注", "Moderate quota — focused"),
        "robot.50": Entry("额度过半，平淡", "Past halfway — neutral"),
        "robot.40": Entry("额度偏低，担忧", "Low quota — worried"),
        "robot.30": Entry("额度较低，紧张", "Lower quota — tense"),
        "robot.20": Entry("额度很低，晕厥", "Very low quota — dizzy"),
        "robot.10": Entry("额度即将耗尽，焦虑", "Nearly exhausted — anxious"),
        "robot.0": Entry("额度已耗尽", "Quota exhausted"),
        "robot.a11y.waiting": Entry("Token Remain，等待额度数据", "Token Remain, waiting for quota data"),
        "robot.a11y.value": Entry("Token Remain，剩余 %1$d%%，%2$@", "Token Remain, %1$d%% remaining, %2$@"),

        // Shared "AI usage" marker (widgets / complications). Not a proper noun — a
        // plain label that must switch with the language.
        "mark.ai_usage": Entry("AI 用量", "AI usage"),

        // Demo scenario names (Settings scenario picker)
        "scenario.concept": Entry("设计稿", "Concept"),
        "scenario.deficit": Entry("超预算节奏", "Deficit pace"),
        "scenario.critical": Entry("额度告急", "Critical"),
        "scenario.freshreset": Entry("刚刚重置", "Fresh reset"),

        // Screenshot/gallery tooling label
        "gallery.corner.actual": Entry("真实角标尺寸", "Actual corner size"),

        // Widget & complication gallery metadata (display name + description). These
        // are rendered by each widget's `body`, so they resolve per widget-process
        // language just like every other string.
        "widget.name.quota": Entry("Token Remain · 额度", "Token Remain · Quota"),
        "widget.name.percent": Entry("Token Remain · 百分比", "Token Remain · %"),
        "widget.name.reset": Entry("Token Remain · 重置", "Token Remain · Reset"),
        "widget.name.rings": Entry("Token Remain · 剩余环", "Token Remain · Remaining rings"),
        "widget.name.corner": Entry("Token Remain · 角标", "Token Remain · Corner"),
        "widget.name.inline": Entry("Token Remain · 单行", "Token Remain · Inline"),
        "widget.desc.min": Entry("最低剩余额度", "Minimum remaining quota"),
        "widget.desc.reset": Entry("下次额度重置", "Next quota reset"),
        "widget.desc.quota": Entry("Claude 与 Codex 额度", "Claude and Codex quota"),
        "widget.desc.rings": Entry("Claude + Codex 剩余环", "Claude + Codex remaining rings"),
        "widget.desc.status": Entry("额度状态", "Quota status"),
        "widget.desc.corner": Entry("AI 用量 · 最低剩余", "AI usage · minimum remaining")
    ]
}
