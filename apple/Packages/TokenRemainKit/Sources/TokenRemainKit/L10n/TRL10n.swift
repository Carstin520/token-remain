import Foundation

/// Shared catalogue for every TokenRemain Apple surface.
///
/// Deliberately a plain Swift table rather than a `.xcstrings` resource: the kit is
/// linked into two widget extensions and a watch app, so a single pure lookup avoids
/// host-bundle differences. Lightweight `.lproj` markers only advertise supported
/// languages for system/per-app language selection. Lookup remains injectable and
/// testable without swizzling `Locale`.
public enum TRL10n {
    public enum Language: String, Sendable, CaseIterable {
        case en
        case zhHans
        case zhHant
        case es
        case de
        case ja
        case ko
    }

    /// The UI language, resolved once per process from the system.
    ///
    /// Resolution follows the system language automatically: `-AppleLanguages` launch
    /// overrides, the per-app language (Settings › TokenRemain › Language) and the
    /// device language all flow through the two signals scanned by `resolve`, so the
    /// whole interface switches with the system without any in-app language control.
    public static let current: Language = resolve()

    /// The `Locale` that matches the resolved UI language, so dates (weekday names,
    /// month names) render in the same language as the rest of the interface rather
    /// than following the device region. Without this, a zh-Hans UI on an en device
    /// would render "Fri" instead of "周五". Keyed off the same `current` resolution
    /// as every string, so a language and its dates never disagree.
    public static var locale: Locale {
        locale(for: current)
    }

    static func locale(for language: Language) -> Locale {
        switch language {
        case .en: return Locale(identifier: "en")
        case .zhHans: return Locale(identifier: "zh_Hans")
        case .zhHant: return Locale(identifier: "zh_Hant")
        case .es: return Locale(identifier: "es")
        case .de: return Locale(identifier: "de")
        case .ja: return Locale(identifier: "ja")
        case .ko: return Locale(identifier: "ko")
        }
    }

    /// Resolves the UI language from the system.
    ///
    /// The primary signal is `Locale.preferredLanguages` — the user's ordered language
    /// preference, which honours the device language, the per-app language override
    /// (Settings › TokenRemain › Language) and the `-AppleLanguages` launch argument
    /// alike. `Bundle.module.preferredLocalizations` (the kit bundle's declared
    /// localizations intersected with the user's languages) follows as a corroborating
    /// fallback. The module advertises every supported language. Both signals are
    /// per-process, so a widget or watch extension resolves in exactly the language
    /// its host process was launched in.
    ///
    /// Unmatched system languages fall back to English (the kit's base localization)
    /// rather than defaulting to Chinese. `preferred` is injectable for tests.
    static func resolve(
        _ preferred: [String] = Locale.preferredLanguages + Bundle.module.preferredLocalizations
    ) -> Language {
        for code in preferred {
            let lower = code.lowercased()
            if lower.hasPrefix("zh-hant")
                || lower.hasPrefix("zh-tw")
                || lower.hasPrefix("zh-hk")
                || lower.hasPrefix("zh-mo") {
                return .zhHant
            }
            if lower.hasPrefix("zh") { return .zhHans }
            if lower.hasPrefix("en") { return .en }
            if lower.hasPrefix("es") { return .es }
            if lower.hasPrefix("de") { return .de }
            if lower.hasPrefix("ja") { return .ja }
            if lower.hasPrefix("ko") { return .ko }
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
        case .en: return entry.en
        case .zhHans: return entry.zh
        case .zhHant, .es, .de, .ja, .ko:
            return supplementalTranslations[language]?[key] ?? entry.en
        }
    }

    public static func f(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: arguments)
    }

    public static func f(_ key: String, language: Language, _ arguments: any CVarArg...) -> String {
        String(
            format: t(key, language: language),
            locale: locale(for: language),
            arguments: arguments
        )
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
            "iPhone 不读取 provider 凭证。请在 Mac 上运行 TokenRemain，并让两台设备登录同一 iCloud 账户且开启 iCloud 钥匙串；App 会自动连接。也可以打开演示模式查看明确标注的示例数据。",
            "iPhone never reads provider credentials. Run TokenRemain on your Mac with both devices signed into the same iCloud account and iCloud Keychain enabled; the apps connect automatically. You can also enable Demo Mode to view clearly-labelled sample data."
        ),
        "origin.demo.status": Entry("全部数据源正常", "All sources nominal"),
        "origin.none.status": Entry("未连接数据源", "No data source"),
        "origin.macsync.status": Entry("来自 Mac 的加密快照", "Encrypted snapshot from Mac"),
        "origin.macsync.freshness": Entry("来自 Mac · %@", "From Mac · %@"),
        "origin.macsync.expired": Entry("Mac 数据已过期", "Mac data expired"),
        "demo.chip": Entry("演示", "DEMO"),
        "demo.a11y": Entry("演示数据", "Demo data"),
        "privacy.statement": Entry(
            "默认仅在本机处理。Mac 同步只把白名单额度快照写入应用层加密的 iCloud 私有数据库；每日 Token/费用历史需在 Mac 单独授权，provider 凭证永不上传。",
            "Processing is local by default. Mac sync writes only an allowlisted quota snapshot into your app-layer-encrypted private iCloud database; daily token/cost history needs separate Mac authorization, and provider credentials are never uploaded."
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
        "overview.trend.empty": Entry("暂无每日用量历史", "No daily usage history yet"),
        "overview.cta": Entry("查看最紧张窗口", "View tightest window"),
        "overview.provider.hint": Entry("轻点查看该数据源的窗口详情", "Tap for this source's window details"),
        "overview.today.today": Entry("今日", "Today"),
        "overview.today.yesterday": Entry("昨日", "Yesterday"),
        "overview.today.recent": Entry("近 %d 天", "Last %d days"),
        "overview.today.trend": Entry("用量趋势", "Usage trend"),
        "overview.today.cost.a11y": Entry("今日用量，估算成本 %@ 美元", "Today's usage, estimated cost %@ US dollars"),
        "overview.widget.manage": Entry("管理概览组件", "Manage overview widgets"),
        "overview.widget.visible": Entry("正在显示", "Shown"),
        "overview.widget.add": Entry("添加组件", "Add widget"),
        "overview.widget.all.visible": Entry("所有组件均已显示", "All widgets are shown"),
        "overview.widget.hide": Entry("隐藏组件", "Hide widget"),
        "overview.widget.move": Entry("移动组件", "Move widget"),
        "overview.widget.move.up": Entry("上移", "Move up"),
        "overview.widget.move.down": Entry("下移", "Move down"),
        "overview.widget.options": Entry("组件选项", "Widget options"),
        "overview.widget.expand": Entry("展开窗口", "Expand windows"),
        "overview.widget.collapse": Entry("收起窗口", "Collapse windows"),
        "overview.feed.title": Entry("精选 X 动态", "Curated X posts"),
        "overview.feed.empty": Entry("Mac 正在筛选公开 X 动态；有真实内容后会加密同步到这里。", "Mac is curating public X posts. Real posts will appear here after encrypted sync."),
        "overview.feed.freshness": Entry("Mac 筛选于 %@", "Curated on Mac %@"),
        "overview.feed.open.hint": Entry("在 X 中打开这条公开动态", "Open this public post on X"),

        // Limits
        "limits.window.caption": Entry("官方额度窗口", "Official quota window"),
        "limits.freshness": Entry("官方数据更新于 %@", "Official data updated %@"),
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
        "trends.title.usage": Entry("每日用量趋势", "Daily usage trend"),
        "trends.subtitle.usage": Entry("Claude + Codex 堆叠 · 来自 Mac 本地 ccusage", "Claude + Codex stacked · local Mac ccusage"),
        "trends.range": Entry("范围", "Range"),
        "trends.metric": Entry("指标", "Metric"),
        "trends.metric.tokens": Entry("Tokens", "Tokens"),
        "trends.metric.cost": Entry("费用", "Cost"),
        "trends.readout.latest": Entry("最新一天", "Latest day"),
        "trends.readout.selected": Entry("已选", "Selected"),
        "trends.readout.a11y": Entry("%1$@，Claude %2$@，Codex %3$@", "%1$@, Claude %2$@, Codex %3$@"),
        "trends.value.tokens.a11y": Entry("%@ Tokens", "%@ tokens"),
        "trends.value.cost.a11y": Entry("估算费用 %@ 美元", "Estimated cost %@ US dollars"),
        "trends.totals.title": Entry("近 %d 天合计", "%d-day total"),
        "trends.totals.combined": Entry("合计", "Total"),
        "trends.empty.title": Entry("每日历史积累中", "Daily history is accumulating"),
        "trends.meta.days": Entry("已同步 %d 天真实历史", "%d days of real history synced"),
        "trends.meta.captured": Entry("Mac 最近采集 %@", "Last captured on Mac %@"),
        "trends.chart.a11y": Entry("%d 天堆叠柱状图，指标 %@", "%d-day stacked bar chart, metric %@"),
        "trends.privacy": Entry(
            "历史只含 Claude / Codex 的按日 Token 与估算费用；不含账号、提示词、项目、会话或逐请求明细。",
            "History contains only daily Claude/Codex tokens and estimated cost; no accounts, prompts, projects, sessions, or request-level details."
        ),
        "trends.title.min": Entry("最低剩余（按天）", "Lowest remaining (daily)"),
        "trends.title.provider": Entry("各数据源剩余", "Remaining by source"),
        "trends.meta.points": Entry("记录点数 %d", "%d recorded points"),
        "trends.meta.earliest": Entry("最早记录 %@", "Earliest record %@"),
        "trends.empty": Entry(
            "需要 Mac 至少积累两天 ccusage 历史，并在桌面端单独开启“同步每日 Token / 费用历史”。这里不会用额度快照虚构曲线。",
            "At least two days of Mac ccusage history are required, with Daily Token/Cost History explicitly enabled on Mac. Quota snapshots are never turned into an invented curve."
        ),

        // Settings
        "settings.section.source": Entry("数据源", "Data source"),
        "settings.origin.row": Entry("当前来源", "Current origin"),
        "settings.demo.toggle": Entry("演示模式", "Demo Mode"),
        "settings.macsync.toggle": Entry("从 Mac 安全同步", "Secure sync from Mac"),
        "settings.macsync.refresh": Entry("立即从 iCloud 拉取", "Pull from iCloud now"),
        "settings.macsync.retry": Entry("立即重试", "Retry now"),
        "settings.macsync.confirm": Entry("确认改用这台 Mac", "Confirm this Mac as source"),
        "settings.sync.automatic": Entry("自动同步", "Automatic sync"),
        "settings.sync.automatic_on": Entry("已开启", "On"),
        "settings.sync.automatic_detail": Entry(
            "首次启动自动自检；等待连接时会快速重试，连接后每 45 秒检查。进入后台后由 iCloud 变更唤醒。",
            "Runs a self-check on first launch, retries quickly while connecting, then checks every 45 seconds. iCloud changes wake it in the background."
        ),
        "settings.sync.health.icloud": Entry("iCloud", "iCloud"),
        "settings.sync.health.key": Entry("同步密钥", "Sync key"),
        "settings.sync.health.snapshot": Entry("Mac 快照", "Mac snapshot"),
        "settings.sync.health.available": Entry("可用", "Available"),
        "settings.sync.health.unavailable": Entry("不可用", "Unavailable"),
        "settings.sync.health.ready": Entry("已就绪", "Ready"),
        "settings.sync.health.waiting": Entry("正在等待", "Waiting"),
        "settings.sync.health.found": Entry("已找到", "Found"),
        "settings.sync.health.not_found": Entry("尚未找到", "Not found yet"),
        "settings.sync.health.pending": Entry("检查中", "Checking"),
        "settings.sync.last_check": Entry("最近自动检查", "Last automatic check"),
        "settings.sync.provider_captured": Entry("Provider 采集", "Provider captured"),
        "settings.sync.phone_rendered": Entry("手机呈现", "Phone rendered"),
        "settings.sync.latency": Entry(
            "前台时延 · p50 %.0f 秒 · p95 %.0f 秒 · 最大 %.0f 秒 · n=%d",
            "Foreground latency · p50 %.0fs · p95 %.0fs · max %.0fs · n=%d"
        ),
        "settings.sync.pulling": Entry("正在安全拉取…", "Securely pulling…"),
        "settings.sync.waiting_mac": Entry("等待 Mac 上传第一份快照", "Waiting for the first Mac snapshot"),
        "settings.sync.waiting_key": Entry("等待 iCloud 钥匙串同步密钥", "Waiting for the iCloud Keychain sync key"),
        "settings.sync.synced": Entry("已同步 · %@", "Synced · %@"),
        "settings.sync.latest_snapshot": Entry("最新快照 · %@", "Latest snapshot · %@"),
        "settings.sync.source_change": Entry("检测到新的 Mac 数据源，需要确认", "A new Mac source needs confirmation"),
        "settings.sync.error.account": Entry("iCloud 账户不可用或未授权", "iCloud account unavailable or unauthorized"),
        "settings.sync.error.temporary": Entry("iCloud 暂不可用，稍后可重试", "iCloud is temporarily unavailable; retry later"),
        "settings.sync.error.remote": Entry("等待 Mac 上传快照", "Waiting for a Mac snapshot"),
        "settings.sync.error.key": Entry("等待 iCloud 钥匙串同步密钥", "Waiting for the iCloud Keychain sync key"),
        "settings.sync.error.security": Entry(
            "远端快照未通过安全校验，已保留旧数据",
            "Remote snapshot failed security validation; old data was kept"
        ),
        "sync.guidance.mac_message": Entry(
            "请在 Mac 上打开 TokenRemain。Mac 会自动检查 iCloud、创建同步密钥并上传第一份加密快照，无需手动开启同步。",
            "Open TokenRemain on your Mac. It will check iCloud, create the sync key, and upload the first encrypted snapshot automatically."
        ),
        "sync.guidance.icloud_message": Entry(
            "请确认已登录 iCloud 并开启 iCloud Drive。路径：设置 > 你的名字 > iCloud。恢复后 TokenRemain 会自动重试。",
            "Confirm that you are signed in to iCloud and iCloud Drive is on: Settings > your name > iCloud. TokenRemain retries automatically."
        ),
        "sync.guidance.keychain_message": Entry(
            "已找到 Mac 快照，但同步密钥仍未到达。请确认两台设备使用同一 Apple 账户，并前往“设置 > 你的名字 > iCloud > 密码与钥匙串”开启同步。",
            "The Mac snapshot was found, but its key has not arrived. Confirm both devices use the same Apple Account and turn on Passwords & Keychain in Settings > your name > iCloud."
        ),
        "sync.guidance.review": Entry("查看诊断", "Review status"),
        "sync.guidance.later": Entry("稍后", "Later"),
        "settings.demo.footer": Entry(
            "Mac 同步使用 iCloud 私有数据库和应用层加密；每日 Token/费用历史需在 Mac 单独授权，provider 凭证永不上传。演示模式只使用确定性示例数据。",
            "Mac sync uses your private iCloud database plus app-layer encryption; daily token/cost history needs separate Mac authorization, and provider credentials are never uploaded. Demo Mode uses deterministic sample data only."
        ),
        "settings.scenario": Entry("演示场景", "Demo scenario"),
        "settings.section.liveactivity": Entry("实时活动", "Live Activity"),
        "settings.liveactivity.start": Entry("开始实时活动", "Start Live Activity"),
        "settings.liveactivity.stop": Entry("停止实时活动", "Stop Live Activity"),
        "settings.liveactivity.active": Entry("运行中", "Running"),
        "settings.liveactivity.inactive": Entry("未运行", "Not running"),
        "settings.liveactivity.denied": Entry("系统已关闭实时活动权限，请在「设置 › TokenRemain」中开启。", "Live Activities are disabled for this app in iOS Settings."),
        "settings.liveactivity.needsdemo": Entry("实时活动只显示演示数据，请先打开演示模式。", "Live Activity only shows demo data — turn on Demo Mode first."),
        "settings.liveactivity.needssource": Entry("连接 Mac 同步或打开演示模式后才能开始。", "Connect Mac sync or enable Demo Mode first."),
        "settings.section.widgets": Entry("小组件", "Widgets"),
        "settings.widgets.home": Entry("长按主屏幕空白处 › 编辑 › 添加小组件 › TokenRemain", "Touch and hold the Home Screen › Edit › Add Widget › TokenRemain"),
        "settings.widgets.lock": Entry("锁定屏幕 › 自定义 › 添加小组件 › TokenRemain", "Lock Screen › Customize › Add Widgets › TokenRemain"),
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
        "intent.open.title": Entry("查看 TokenRemain", "Open TokenRemain"),
        "intent.startla.title": Entry("开始实时活动", "Start Live Activity"),
        "intent.stopla.title": Entry("停止实时活动", "Stop Live Activity"),
        "intent.startla.done": Entry("实时活动已开始", "Live Activity started"),
        "intent.stopla.done": Entry("实时活动已停止", "Live Activity stopped"),

        // Live Activity
        "liveactivity.indicator": Entry("实时", "LIVE"),
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
        "watch.waiting.body": Entry("在 iPhone 上打开 TokenRemain 即可同步最新快照。", "Open TokenRemain on iPhone to sync the latest snapshot."),

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
        "robot.a11y.waiting": Entry("TokenRemain，等待额度数据", "TokenRemain, waiting for quota data"),
        "robot.a11y.value": Entry("TokenRemain，剩余 %1$d%%，%2$@", "TokenRemain, %1$d%% remaining, %2$@"),

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
        "widget.name.quota": Entry("TokenRemain · 额度", "TokenRemain · Quota"),
        "widget.name.percent": Entry("TokenRemain · 百分比", "TokenRemain · %"),
        "widget.name.reset": Entry("TokenRemain · 重置", "TokenRemain · Reset"),
        "widget.name.rings": Entry("TokenRemain · 剩余环", "TokenRemain · Remaining rings"),
        "widget.name.corner": Entry("TokenRemain · 角标", "TokenRemain · Corner"),
        "widget.name.inline": Entry("TokenRemain · 单行", "TokenRemain · Inline"),
        "widget.desc.min": Entry("最低剩余额度", "Minimum remaining quota"),
        "widget.desc.reset": Entry("下次额度重置", "Next quota reset"),
        "widget.desc.quota": Entry("Claude 与 Codex 额度", "Claude and Codex quota"),
        "widget.desc.rings": Entry("Claude + Codex 剩余环", "Claude + Codex remaining rings"),
        "widget.desc.status": Entry("额度状态", "Quota status"),
        "widget.desc.corner": Entry("AI 用量 · 最低剩余", "AI usage · minimum remaining")
    ]
}
