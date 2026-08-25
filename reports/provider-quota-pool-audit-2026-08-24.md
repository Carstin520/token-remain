# Provider 多额度池适配审计(2026-08-24)

背景:Cursor 修复(双池 autoPercentUsed/apiPercentUsed 被 totalPercentUsed 混合掩盖)后,
对全部 provider 解析器做同类问题排查:上游报告的独立额度维度 vs. 解析器实际映射的维度,
找"混合成一条 / 静默丢弃 / 只取总量"三种模式。审计由 4 个 Opus subagent 完成,
证据以测试 fixture 与解析代码 file:line 为准;两处最严重结论(Copilot、ZCode 断同步)已人工复核。

## 结论总表

| Provider | 上游维度 | 已映射 | Verdict | 置信度 |
|---|---|---|---|---|
| **Copilot(免费档)** | 5(premium/chat/completions/overage/旧计数) | 2 | 🔴 高危:双 43200min 窗口→整份手机同步 fail-closed;固定 chat 做 primary 掩盖 completions;overage 丢失 | 高(已复核) |
| **Z.ai ZCode start-plan** | N 个模型级命名池(fixture 实证 2) | 2 | 🔴 高危:按池大小而非用量排序;show_name 丢弃;双 43200min 窗口断同步;第 3+ 池丢弃 | 高(已复核) |
| **Qoder(HTTP)** | 2(totalQuota+sharedQuota) | 1 | 🔴 高危:客户端两池求和稀释,Cursor 逐字复刻(个人池耗尽+团队池未动=显示剩 91%) | 高 |
| **Codex(本地快照)** | 账户 5h/7d + 每模型 5h/7d | 3 | 🔴 模型池(Spark)的 5h 窗解析后丢弃,模型池 5h 耗尽无任何提示 | 高 |
| **Antigravity** | 4 bucket(gemini/3p × 5h/weekly) | 4(2 个默认不可见) | 🟠 3P 池默认隐藏且不进 meter,与 Fable"藏掉=藏掉瓶颈"设计矛盾;未知 bucketId 静默丢;scoped 未设 observedAt 会闪断 | 高 |
| **Ollama** | 3(Session/Hourly/Weekly) | 2 | 🟠 Session 与 Hourly 抢同一槽,显示哪个取决于 HTML 顺序 | 高 |
| **MiMo** | 4(钱包/套餐/month_total_token/day_token) | 3 | 🟠 day_token 被吞(当天耗尽仍显示月度 25%);lowestRemaining 策略下空钱包(0min 窗)会劫持菜单栏 | 高 |
| **Kimi** | limits[] 动态 N 窗 | 2 | 🟠 日窗(1440)与周窗(10080)抢同一槽,先到胜;第 3 窗丢弃;无 scoped 兜底 | 中 |
| **Z.ai monitor(个人+GLM Team)** | limits[] 开放数组 | ≤3 | 🟠 未知 type 静默丢;同时长去重丢池;≥3 窗丢中间档;TIME_LIMIT 硬编码 30 天+"MCP"标签(fixture 里实际是 1 分钟);Team 版全盘继承且组织响应形状未验证 | 中 |
| **Claude(PTY 兜底)** | 5 | 3 | 🟠 `Current session (X)` 不解析 scope 且 last-wins,模型级会话额度会顶掉账户 5h;降级时套餐名/extraUsage 消失 | 中高 |
| **Volcengine** | ≥1(未知) | 1 | 🟡 递归取首个 Percent,Dictionary 遍历顺序跨启动随机——多池时今天显示 A 明天显示 B | 高(不确定性) |
| **Grok** | 3 | 1.5 | 🟡 onDemandCap(按量上限)未解析,主池打满仍在扣费但只显示 0% 剩余;settings 整份只取套餐名 | 高 |
| **OpenRouter** | 2(积分钱包+key 限额) | 1.5 | 🟡 key 无周期时积分池降级为纯余额,"已用 99%"百分比维度丢失;取舍有注释有测试,但 scopedWindows 出口未用 | 高 |
| **DeepSeek** | 多币种×3 子池 | 1 | 🟡 只取首个有余额币种的 total;granted/topped_up 拆分丢弃 | 中 |
| **Copilot/Grok 共性** | — | — | 🟡 ExtraUsage 模型已备好但 overage/onDemand 均未接 | — |
| **Qoder(本地 IPC)** | ≥1 | 1 | 🟡 优先取 totalUsagePercentage 汇总值(Cursor 形状),需抓真实响应定性 | 中 |
| **OpenCode** | 3(本地估算) | 3 | 🟢 基本 OK;月池 scoped 不进 meter、收起不可见(弱化版同类) | 高 |
| **Kiro** | 未知(CLI 文本) | 1 | ⚪ 只取首个正则匹配;无真机输出留档,无法定性 | 低 |
| **Devin / Windsurf** | 2 | 2 | 🟢 OK;两文件是复制粘贴关系,改动需同步;无真实响应 fixture | 中 |
| **MiniMax** | 2+2N | 全部 | 🟢 OK,唯一已按命名池正确铺开的实现(与 Cursor 修复后形态一致);无 general 行时任取第 0 行属边角 | 高 |
| **Claude(OAuth API)** | 5 | 5 | 🟢 OK;scope.surface 池与未知 kind 静默丢弃属前瞻隐患;session 行不校验 scope | 高 |
| **Codex(wham API)** | 4 | 3.5 | 🟢 OK;applicable_available_count 有意不用(已文档化) | 高 |
| **Third-party/New API** | 1/配置 | 1 | 🟢 OK;aff_quota/request_count 未解析属推断 | 中 |
| **HostApp 路由** | 透传 | 全量 | 🟢 多窗口 OK;但凭证回落口径与自身 MiMo 注释矛盾(key 缺失时会回落 env/钥匙串,可能误挂另一账户) | 高 |

## 三类系统性模式

1. **同步 fail-closed 放大器**:`MobileUsageSnapshot` 校验拒绝同 provider 两个同时长账户级窗口,
   且是整份快照拒收。Copilot 免费档与 ZCode start-plan 今天就会触发——一个 provider 打挂所有 provider 的手机同步。
   凡两池同时长,secondary 是禁区,必须走 scopedWindows(允许同时长,scopeID `[a-z0-9_-]{1,32}`)。
2. **槽位挤占**:primary/secondary 只有两个槽,Kimi/Ollama/Z.ai 都在用 if-nil 抢槽,
   先到先得、后到静默丢弃,且无一处有注释。第 3+ 维度应一律进 scopedWindows。
3. **选择标准错误**:合并/取舍时用"池子大小"(ZCode)、"字段顺序"(Copilot chat 优先、Volcengine 随机遍历)
   而不是"哪个池最紧张"。Cursor 修复确立的约定是:忙池做 primary(带 poolName),兄弟池做命名 scoped 窗口。

## 建议修复优先级

1. **Copilot 免费档 + ZCode start-plan**(断同步,影响全局):忙池 primary + 兄弟池 scoped,一次修掉断同步与掩盖两个问题。
2. **Qoder HTTP 求和稀释**(证据确凿,测试把错误行为固化,需连测试一起改)。
3. **Codex 模型池 5h 窗丢弃**(fixture 直接证明维度被丢)。
4. **Ollama 三维挤两槽 / MiMo day_token / Antigravity 3P 默认可见性**(各为一行到数行的小改)。
5. **Volcengine 确定性遍历**(即使单池也应修,行为随机)。
6. **Kimi / Z.ai monitor 槽位重构**(建议先抓真实多窗响应再定形)。
7. **ExtraUsage 补全**(Copilot overage、Grok onDemandCap)与 OpenRouter 积分池 scoped 化。
8. 待取证:Kiro 真机 CLI 输出、Qoder IPC 真实响应、GLM Team 组织版响应、Devin/Windsurf 完整 proto。
