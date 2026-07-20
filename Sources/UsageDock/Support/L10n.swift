import Foundation

/// One localization gateway for strings created outside SwiftUI's literal
/// `Text`/`Button` initializers. Static SwiftUI literals are resolved by the
/// same Localizable.strings files through Bundle.main.
enum L10n {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        let localized = bundle.localizedString(forKey: key, value: key, table: nil)
        return localized == key ? fallback[key] ?? key : localized
    }

    static func format(
        _ key: String,
        _ arguments: CVarArg...,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(format: text(key, bundle: bundle), locale: locale, arguments: arguments)
    }

    static func usd(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// SwiftPM tests do not run inside the assembled .app bundle. This keeps
    /// domain strings deterministic there and is also the final safety net if
    /// an installed localization is missing a key.
    private static let fallback: [String: String] = [
        "widget.local_usage": "今日本地统计",
        "widget.ai_feed": "AI动态",
        "usage.api_cost": "API 花费",
        "nav.group.monitor": "监测",
        "nav.group.system": "系统",
        "nav.overview": "概览",
        "nav.limits": "额度",
        "nav.trends": "趋势",
        "nav.devices": "设备",
        "nav.data_sources": "数据来源",
        "nav.settings": "设置",
        "section.overview.subtitle": "掌握额度风险、今日用量与预估成本",
        "section.limits.subtitle": "Claude 与 Codex 官方额度窗口明细",
        "section.trends.subtitle": "跨天使用趋势 · 本地 ccusage",
        "section.devices.subtitle": "本机与未来跨设备监测",
        "section.data_sources.subtitle": "数据来源状态与隐私说明",
        "section.settings.subtitle": "启动项、刷新与应用操作",
        "sync.partial_error": "部分数据源异常",
        "sync.loading": "正在读取数据…",
        "sync.healthy": "全部数据源正常",
        "risk.badge.low": "低",
        "risk.badge.medium": "中",
        "risk.badge.high": "高",
        "risk.headline.low": "使用节奏健康",
        "risk.headline.medium": "注意用量节奏",
        "risk.headline.high": "额度即将耗尽",
        "risk.headline.unknown": "等待官方额度",
        "risk.headline.projected_runout": "当前节奏可能提前用尽",
        "risk.summary.low": "按当前节奏，额度充足，可以安心使用到下次重置。",
        "risk.summary.medium": "部分窗口额度偏低，建议放缓用量或关注重置时间。",
        "risk.summary.high": "额度即将耗尽，请谨慎使用，必要时等待窗口重置。",
        "risk.summary.unknown": "尚未读取到官方额度快照，稍后将自动重试。",
        "risk.summary.projected_runout": "%1$@ %2$@窗口按当前平均节奏预计 %3$@ 后用尽，早于官方重置。建议放缓或切换服务商。",
        "feed.tier.primary": "第一梯队",
        "feed.tier.rotating": "第二梯队",
        "feed.priority.token": "额度 / Token",
        "feed.priority.update": "重大更新",
        "feed.priority.normal": "动态",
        "duration.days_hours_minutes": "%1$d天 %2$d小时 %3$d分",
        "duration.days_hours": "%1$d天 %2$d小时",
        "duration.hours_minutes": "%1$d小时 %2$d分",
        "duration.minutes": "%d分钟",
        "duration.less_than_minute": "不到 1 分钟",
        "duration.hours": "%d小时",
        "duration.days": "%d天",
        "reset.in_progress": "正在重置",
        "reset.countdown": "重置还有 %1$@",
        "reset.on": "%1$@ 重置",
        "freshness.just_now": "刚刚更新",
        "freshness.minutes": "%d 分钟前更新",
        "freshness.hours": "%d 小时前更新",
        "freshness.days": "%d 天前更新",
        "quota.window": "%1$@窗口",
        "quota.remaining": "剩余 %1$@",
        "quota.window_accessibility": "%1$@ %2$@窗口",
        "pace.on_track": "节奏正常",
        "pace.reserve": "节奏余量 %1$@",
        "pace.deficit": "用量超前 %1$@",
        "pace.lasts_until_reset": "可持续到重置",
        "pace.projected_early": "预计提前用尽",
        "pace.projected_in": "预计 %1$@ 后用尽",
        "widget.all_visible": "所有组件均已显示",
        "widget.add_named": "添加%1$@",
        "widget.keep_expanded": "保持展开",
        "widget.stop_keep_expanded": "取消保持展开",
        "widget.collapse": "折叠",
        "widget.expand": "展开",
        "widget.move_up": "上移",
        "widget.move_down": "下移",
        "widget.remove_named": "移除%1$@组件",
        "widget.drag_help": "拖动组件顶部调整位置；右键查看更多操作",
        "widget.drag_accessibility": "可拖动调整位置，或打开上下文菜单移除组件",
        "action.add_widget": "添加组件",
        "action.refresh_quota": "立即刷新 ccusage、Codex 与 Claude 官方额度",
        "action.refresh_usage": "刷新用量",
        "action.open_dashboard": "打开 Dashboard",
        "action.open_dashboard_help": "打开独立的 Token Remain Dashboard 窗口",
        "action.launch_at_login": "登录时自动启动",
        "action.open_dashboard_settings": "打开 Dashboard 设置",
        "action.restart_app": "重启 Token Remain",
        "action.settings": "设置",
        "action.quit": "退出",
        "action.quit_app": "退出 Token Remain",
        "usage.updated_local": "更新于 %1$@ · 数据留在本机",
        "usage.loading_local": "正在读取用量 · 数据留在本机",
        "usage.provider_breakdown_empty": "暂无按服务商拆分",
        "usage.loading_ccusage": "正在读取 ccusage 本地统计…",
        "usage.provider_help": "%1$@：%2$@ API 花费，%3$@ tokens，占 %4$@",
        "usage.provider_accessibility": "%1$@，%2$@ API 花费，%3$@ tokens",
        "quota.loading_official": "正在读取官方额度…",
        "feed.updating": "更新中",
        "feed.item_count": "%d 条",
        "feed.filtering": "正在筛选值得关注的新动态…",
        "feed.full_top_stories": "热门内容全文",
        "feed.important_updates": "精选重要动态",
        "feed.view_all": "查看全部",
        "feed.open_x_hint": "在 X 打开原帖"
    ]
}
