# Provider 多额度池修复方案(2026-08-24)

对应审计:`provider-quota-pool-audit-2026-08-24.md`。

## 统一原则

1. **数据层与展示层分离**。解析器无条件把所有维度解析全——不混合、不丢弃、不抢槽;
   开关只决定"显不显示",不决定"存不存在"。数据先修对,才谈偏好。
2. **槽位抢占最优先**(Copilot、ZCode、Kimi、Ollama、Z.ai monitor、Codex Spark 5h、Qoder):
   这些是正确性 bug,不做开关,直接修。
3. **附加进度条沿用 Spark 式开关 + 智能默认**:偏好键未设置时,按"该池是否在用"决定默认值——
   该池有过非零用量 → 默认显示;从未用过 → 默认隐藏。用户动过开关后,存储值永久优先
   (实现上沿用 Fable 的 `defaults.object(forKey:) as? Bool ?? 智能默认` 写法,不能用 `defaults.bool`)。
   这把现状合理化:Fable 默认开(Claude 用户都在用)、Spark/3P 默认关(少数人用)——
   以后不用逐个手拍默认值,数据说了算。
4. **账户级主池永不进开关**。headline 一律取最忙的账户级池(Cursor 约定:忙池做 primary
   带 poolName,兄弟池做命名 scoped),防止掩盖瓶颈。开关只管模型级/附加池的那几行。

## 逐案方案

### 第一批:槽位抢占 + 断同步(无条件修,无开关)

**1. Copilot 免费档**(`CopilotUsageService.swift:93-109`)
- chat/completions 中较忙者 → primary(poolName "Chat" / "Completions"),另一池 → scoped
  (`copilot_chat` / `copilot_completions`)。付费档 premium 逻辑不变。
- 一次修掉两个问题:双 43200 窗口断同步 + 固定 chat 优先的掩盖。
- 用户习惯:与 Cursor 卡完全同形——收起看最紧的,展开看两条,GitHub 计费页也是分开列的。

**2. Z.ai ZCode start-plan**(`ZCodeCredentialReader.swift:357-389`)
- 最忙模型池 → primary(poolName = `show_name`,如 "GLM-5.2");其余全部 → scoped
  (scopeID 由 show_name slug 化),第 3+ 池不再丢弃。
- windowMinutes 从 `period_end - server_time`(或响应时刻)推算,不再硬编码 43200。
- planName 取排序后 primary 桶的 plan_id,修掉"计划名来自另一个桶"。
- 用户习惯:Z.ai 控制台就是按模型分行展示的,名字对得上。

**3. Qoder HTTP 双池**(`QoderUsageService.swift:487-520`)
- 停止求和。个人池(totalQuota)/共享池(sharedQuota)较忙者 → primary
  (poolName "Personal" / "Shared"),另一池 → scoped(`qoder_personal` / `qoder_shared`)。
- 连同固化错误行为的测试一起改("merges total and shared credit pools" 改为拆分断言)。
- 用户习惯:Qoder 控制台本来就分"我的额度/团队共享"两栏。

**4. Kimi 撞槽**(`ExtendedProviderServices.swift:269-285`)
- 按时长排序:最短 → primary,最长 → secondary(时长不同,同步安全),
  中间档(典型是日窗)→ scoped(displayName 用本地化时长词,如 "Daily / 日额度")。
- 任何窗口都不丢。无开关(全是账户级)。

**5. Ollama 三维挤两槽**(`ExtendedProviderServices.swift:1005-1009`)
- Session(300)→ primary、Weekly(10080)→ secondary 维持现状;
  Hourly(60)→ scoped `ollama_hourly`,displayName "Hourly"。
- 三个时长互不相同,同步无风险;命名与 ollama.com 设置页的三个标签逐字一致。

**6. Codex 模型池 5h 丢弃**(`CodexUsageService.swift:339-341`)
- 每个模型池(Spark 等)的 5h 与 7d 两窗都保留,成对 scoped
  (`codex_bengalfox_session` / `codex_bengalfox_weekly`),标题自然渲染为
  "GPT-5.3-Codex-Spark · 5 hr / · 7 d"——与主卡 5h+7d 堆叠的既有习惯完全一致。
- 显示整体仍由现有 Spark 开关控制;开关默认值改为智能默认(Spark 有过用量 → 开)。
- 顺手修 `parseWindow` 强制要求 resets_at 的问题(模型允许 nil,解析器不应更严)。

**7. Z.ai monitor / GLM Team**(`ZAIUsageService.swift:219-253`)
- TIME_LIMIT 按自身 `(unit, number)` 算真实时长;名字用上游 `name`,scopeID 由 name
  slug 化——多条 TIME_LIMIT 不再共用 `zai_mcp_monthly` 塌缩成一条。
- 同时长 token 池不再去重:第一对不同时长的窗进 primary/secondary,其余全部 → scoped。
- 未知 type 先记日志不渲染(避免把未知语义的数字端给用户),拿到真实样本再定。
- GLM Team 复用解析器,自动继承。

### 第二批:展示层(开关 + 智能默认)

**8. Antigravity 3P 池**(`PreferencesStore.swift:99`)
- 开关保留;默认值改智能默认:3P 池 usedPercent > 0(用户真的在走 Claude/3P 配额)→ 默认显示。
  与 Fable "藏掉它=藏掉真正瓶颈"的论证对齐,也符合"没在用就默认关"。
- 补 scoped 的 `observedAt`(修"一次刷新只回 gemini 桶时 3P 行闪断")。
- 未知 bucketId 记日志,不再静默丢。

**9. MiMo**(`ExtendedProviderServices.swift:601-686`)
- `day_token` → scoped "Daily",智能默认(有日用量即显示)。
- 钱包从 secondary 摘出,改挂 `accountBalance`(卡片已有 AccountBalanceRow 这一行,
  用户已认识)——顺带根治 lowestRemaining 策略下"空钱包劫持菜单栏 0%"的问题。

**10. OpenRouter 积分池**(`OpenRouterUsageService.swift:129-141`)
- key 限额无周期时,积分池不再降级成纯余额:改为 scoped "Credits"
  (带 remainingBalance,百分比维度保留)。scoped 允许同时长,同步安全。
- 智能默认:积分池有消耗 → 显示。

**11. DeepSeek 多币种**(`ExtendedProviderServices.swift:139`)
- 首个有余额币种维持主行;其余币种 → scoped 行(displayName 即币种码,带 remainingBalance)。
- granted/topped_up 子池暂不拆(价值低,等有用户诉求)。

### 第三批:正确性小修(无 UI 变化)

**12. Volcengine**(`ExtendedProviderServices.swift:874-887`)——递归遍历按 key 排序,
  优先显式路径 `user_limit.Percent`;发现多个 Percent 记日志。消除跨启动随机显示。

**13. Claude PTY**(`ClaudeUsageService.swift:476-484`)——session 行解析括号 scope;
  带 scope 的会话读数进 scoped,无 scope 的才是账户 5h,废除 last-wins。

**14. ExtraUsage 补全**——Copilot `overage_count` 与 Grok `onDemandCap` 接入
  ExtraUsage(卡片既有"订阅外按量"行,Claude 用户已熟悉该行语义)。

### 待取证(不动手)

Kiro 真机 CLI 输出、Qoder 本地 IPC 真实响应、GLM Team 组织版响应形状、
Devin/Windsurf 完整 proto——各抓一份真实样本后再定性。

## 设置页形态

新增开关继续排在现有 Spark/Fable/3P 三个开关同组,文案沿用"在挂件中显示 X"句式;
不引入新的交互形态。所有开关共用同一套智能默认读取器
(`storedBool(key) ?? poolHasActivity`),Fable/Spark/3P 三个旧键迁移到同一实现。
