# TokenRemain 代理知识库

本文件保存多个宿主都需要、但还不能写成可执行契约的项目事实。规则在 [AGENTS.md](../../AGENTS.md)，本文件不新增授权。按 R15，能变成测试或脚本的条目优先转为契约，见文末“待转为契约”。

每条写明事实、来源（代码路径、PR/issue 或实测记录）和核实日期。条目与当前代码不符时，以代码为准并在规则维护任务中修正本文件；不要把个人记忆当作来源。

<a id="host-capabilities"></a>

## 宿主能力

本节记录本仓库依赖的宿主行为。“实测”指在本机用临时探针仓库验证；“文档”指只核对了官方文档；二者都没有的写“未验证”。

| 宿主与版本 | 事实 | 来源 | 核实日期 |
| --- | --- | --- | --- |
| Claude Code 2.1.267 | 项目根 `CLAUDE.md` 首行 `@AGENTS.md` 会把 AGENTS.md 导入上下文；相对路径按导入文件解析，最多 4 层 | 实测：探针仓库中 AGENTS.md 的 nonce 出现在 `claude -p` 回答里；文档 code.claude.com/docs/en/memory | 2026-09-28 |
| Claude Code 2.1.267 | 扫描 `.claude/skills/<name>/SKILL.md`，跟随指向 `.cursor/skills/<name>` 的目录符号链接；不扫描 `.agents/skills`、`.codex/skills` | 实测：探针仓库中符号链接技能与真实目录技能都被列出，另两处未列出 | 2026-09-28 |
| Claude Code 2.1.267 | `.claude/settings.json` 的 PreToolUse(Bash) hook 以 exit 2 拒绝时，`bypassPermissions` 模式和已放行的工具规则都不能越过；hook 进程继承启动 `claude` 时的环境变量；无 lane 标记时命令正常执行 | 实测：`claude -p` 在临时克隆中运行 `git tag`，以 `git tag -l` 结果为准 | 2026-09-28 |
| Codex CLI 0.144.1 | 读取 AGENTS.md；扫描从 cwd 到仓库根的 `.agents/skills`，跟随符号链接；不扫描 `.cursor/skills`、`.claude/skills` | 实测：`codex debug prompt-input` 输出含对应 nonce，移除 `.agents/skills` 链接后消失；文档 learn.chatgpt.com/docs/build-skills | 2026-09-28 |
| Codex CLI 0.144.1 | 也扫描仓库 `.codex/skills`，但官方文档未列出该路径 | 实测，同上 | 2026-09-28 |
| Codex CLI 0.144.1 | 项目 hook 在 `.codex/hooks.json`，`PreToolUse` 用 matcher `Bash`，命令在 `tool_input.command`，exit 2 或 `permissionDecision: deny` 阻止；项目 hook 须经 `/hooks` 信任后才运行，`codex exec --dangerously-bypass-hook-trust` 可单次跳过信任 | 文档 learn.chatgpt.com/docs/hooks | 2026-09-28 |
| Codex CLI 0.144.1 | 本仓库护栏：带 lane 标记的克隆中 `git tag` 被 hook 拦下且标签未创建；无标记时 hook 运行但放行；未信任 hook 时 hook 完全不运行，所以 lane 预检用 canary 命令确认护栏生效 | 实测：`codex exec`（`gpt-5.6-sol`）在临时克隆中，以 `git tag -l` 结果为准 | 2026-09-28 |
| Codex CLI 0.144.1 | `workspace-write` sandbox 禁止写 `.git`（`git tag` 报 Operation not permitted），默认也不开网络；在此设置下 lane 无法 commit、push 或调用 `gh` | 实测，同上；本机默认 `sandbox_mode = "workspace-write"` 且未设 `network_access` | 2026-09-28 |
| Codex app 定时任务 | 用用户的默认 sandbox 设置运行，组织策略允许时 `approval_policy = "never"`；可选本地项目或新 worktree；文档未说明能否为单个任务设环境变量；定义保存在 `~/.codex/automations/<id>/automation.toml`（`kind`、`rrule`、`execution_environment`、`cwds`、`target`、`model` 等字段） | 文档 learn.chatgpt.com/docs/automations；本机只读查看字段名 | 2026-09-28 |
| Cursor 3.22.7 | 项目 hook 在 `.cursor/hooks.json`（`version: 1`），`beforeShellExecution` 输入含 `command`、`cwd`；exit 2 等同 deny，stdout 字段为 `permission`、`user_message`、`agent_message`；仅在受信任工作区运行，云代理也运行项目命令 hook；文档未说明 hook 是否继承父进程环境变量 | 文档 cursor.com/docs/agent/hooks；本机未实跑 Cursor | 2026-09-28 |
| GitHub Actions | `macos-26` 为 arm64 GA 镜像，macOS 26.6.2（25G83），默认 Xcode 26.6（17F113），与本机开发环境一致 | 文档 github.com/actions/runner-images `macos-26-arm64-Readme.md`（镜像 20260907.0351.1） | 2026-09-28 |

因为 Codex 定时任务与 Cursor hook 的环境变量继承都没有文档保证，lane 身份除环境变量外还认 worktree 私有 git 目录里的标记文件（R14）。

<a id="upstream-baselines"></a>

## 上游基线

Lane B 比较这些基线与上游当前状态。基线变更需要人审阅后在独立 PR 中更新。

| 上游 | 基线 | 来源 | 核实日期 |
| --- | --- | --- | --- |
| pstack（`cursor/plugins` 的 `pstack/`） | 见 [pstack-upstream.json](pstack-upstream.json)；处置表在 `.cursor/rules/tokenremain-pstack.mdc` | 本仓库审阅记录 | 2026-09-28 |
| token-monitor（`Javis603/token-monitor`，MIT） | 移植时的上游提交未记录，状态为“未知”。已知移植落地于本仓库 `697e550`（2026-07-23，首次移植）与 `b4fc28d`（2026-08-04，扩展兼容）；Lane B 首次运行列出 2026-07-23 以来 `src/shared/*Limits.js` 的提交，由人确认基线后写回本表 | `Sources/UsageDock/Services/ExtendedProviderServices.swift` 文件头注释；`git log --follow` | 2026-09-28 |
| ccusage（npm `@ccusage/ccusage-darwin-*`） | `Resources/Info.plist` 的 `TokenRemainBundledCCUsageVersion`；`script/verify_ccusage_freshness.sh --check` 只读比较 npm 最新版（写 `/tmp` 临时目录，陈旧时退出 1），`--update` 会改 `Vendor/`，属于发布任务 | 脚本源码 | 2026-09-28 |

## Provider 接口与凭证

所有 provider 沿用同一形态：只读第三方凭证 → API 客户端 → 纯函数解析器 → 降级链；绝不刷新、写回或迁移第三方 token（R3）。接口多为非公开，变动时对照 README 致谢的 [OpenUsage](https://github.com/robinebers/openusage) 与 token-monitor 的最新实现。

| 事实 | 来源 | 核实日期 |
| --- | --- | --- |
| Claude 主路径是 `GET https://api.anthropic.com/api/oauth/usage`，请求超时 25 秒；429 映射为 `rateLimited(retryAfterSeconds:)`，尊重 Retry-After；失败才降级 PTY `/usage` 探针 | `Sources/UsageDock/Services/ClaudeOAuthUsageService.swift`（`usageURL`、`requestTimeout`） | 2026-09-28 |
| Claude 凭证由 `ClaudeCredentialsReader` 读取：先试 `.credentials.json` 文件，再读钥匙串（含 `/usr/bin/security` 代读）；代码注释记录 Claude Code 2.1+ 已不再写该文件，所以实际多走钥匙串 | 同上，`read(...)`、`filePayloads()`、`readAllowingAppleTool(...)` | 2026-09-28 |
| Codex 主路径是 `wham/usage` 直查，只读 `$CODEX_HOME/auth.json`（默认 `~/.codex/auth.json`），本地会话快照只作降级 | `Services/CodexUsageService.swift`、`Services/CodexAPIUsageService.swift` | 2026-09-28 |
| Cursor 月度额度走 `api2.cursor.sh` 的 `DashboardService/GetCurrentPeriodUsage`；token 用 `sqlite3 -readonly` 读 `state.vscdb`，不代刷；`planUsage.autoPercentUsed` 与 `apiPercentUsed` 是两个独立池，`totalPercentUsed` 是会掩盖先耗尽池的混合值 | `Services/CursorUsageService.swift` | 2026-09-28 |
| DeepSeek、Kimi、MiniMax、MiMo、Qoder、Kiro、Volcengine、Ollama 八家集中在一个文件，口径移植自 token-monitor（MIT），凭据只读（环境变量或用户粘贴的钥匙串条目） | `Services/ExtendedProviderServices.swift` 文件头注释；README 致谢 | 2026-09-28 |
| 诊断直查还是降级：看 `~/Library/Caches/<bundle id>/quota-cache.json` 中 Claude 条目有没有 `planName`，直查会写出套餐名，没有则说明每轮都在走 PTY 降级 | `Services/QuotaCache.swift`；2026-08-14 实测口径 | 2026-09-28 |

**多额度池。** 上游每个独立额度维度都要解析，不混合也不丢弃。同一账期拆池时，最忙的池做 primary 并设 `QuotaWindow.poolName`，兄弟池和第三个以上维度放 `ScopedQuotaWindow`；不要把两个相同 `windowMinutes` 的窗口放进 primary 与 secondary，同步协议会以 `duplicateWindow` 拒收整份快照。可选的附加池注册进 `Models/ScopedPoolToggleCatalog.swift`，可见性走 `PreferencesStore.resolvedScopedPoolVisibility(...)`，存储键统一为 `tokenRemain.scopedPoolVisibility.v1`，不要再造独立布尔键。来源：`Models/UsageModels.swift`、`Stores/PreferencesStore.swift`、`Packages/TokenRemainSyncKit/Tests/.../SyncProtocolTests.swift`；核实 2026-09-28。

## Keychain

| 事实 | 来源 | 核实日期 |
| --- | --- | --- |
| CLI 写入的条目（如 `Claude Code-credentials`）在 file-based login keychain；能抑制其 ACL 授权框的只有 `SecKeychainSetUserInteractionAllowed(false)`，`LAContext.interactionNotAllowed` 与 `kSecUseAuthenticationUIFail` 实测无效，读取会阻塞到用户点击 | `Support/KeychainRead.swift`；`script/verify_keychain_read_contract.sh` 注释；2026-07-25 实测 | 2026-09-28 |
| 该开关是进程级的，set→read→restore 必须串行；串行用 `lock(before:)` 限时等待，不能用 `try()`，否则并发刷新会无谓降级 | `Support/KeychainRead.swift`（`gate.lock(before:)`） | 2026-09-28 |
| `Claude Code-credentials` 的 partition list 只有 `apple-tool:`，GUI 应用点“始终允许”无效；修法是经 `/usr/bin/security` 代读（`genericPasswordViaAppleTool`），先用只读 ACL 元数据确认不会弹框 | `Support/KeychainRead.swift`；2026-08-14 实测 | 2026-09-28 |
| 验证“不弹框”要断言 `needsAuthorization`，不能只断言 `payload == nil`：没有该条目的机器会以 `errSecItemNotFound` 假通过 | `Tests/UsageDockTests/KeychainReadTests.swift`（“A refused item is reported as needing authorization…”） | 2026-09-28 |

## 网络与代理

| 事实 | 来源 | 核实日期 |
| --- | --- | --- |
| API 直查用 URLSession，走系统代理；PTY 探针启动的 claude CLI（node/undici）不认 macOS 系统代理，只认代理环境变量，缺变量时既刷不到用量也续不了 token | `Services/ClaudeProbeNetworkEnvironment.swift` 文件头注释；2026-08-26 实测 | 2026-09-28 |
| 探针启动前按优先级收集候选路线（进程变量、`~/.claude/settings.json` 的 env、系统代理与 PAC、登录 shell、直连），并发预检 `api.anthropic.com`，取最高优先级可达路线；全部不通就不启动探针；PAC 中 CFNetwork 只认 `SOCKS` 关键字 | 同上；`ClaudeProbeNetworkEnvironmentTests` | 2026-09-28 |
| 探针运行期间轮询凭证，token 变新即停止探针改走 API | `Services/ClaudeUsageService.swift`（`ClaudeProbeRenewalWatch`） | 2026-09-28 |

## Dev 与生产隔离

| 事实 | 来源 | 核实日期 |
| --- | --- | --- |
| 普通开发构建是 `TokenRemain Dev` / `UsageDockDev` / `com.jamesli.usagedock.dev`，不覆盖生产 `TokenRemain.app`（`com.jamesli.usagedock`） | `script/build_and_run.sh`、`script/verify_installation_isolation.sh` | 2026-09-28 |
| 两者是独立的 UserDefaults 域，Dev 域残留的外观偏好（`tokenRemain.popoverGlassStyle.v1`、`tokenRemain.popoverBackgroundOpacity.v1`）会让 Dev 看起来像“玻璃回归”；对比前先分别 `defaults read`。默认值是 frosted 与 0.62 | `Stores/PreferencesStore.swift`（`popoverGlassStyleKey`、`defaultPopoverBackgroundOpacity`）；2026-08-21 排查记录 | 2026-09-28 |
| Dev 构建不启动 Sparkle 更新器，也不挂 CloudKit 同步，二者只在 `TOKENREMAIN_CLOUD_SYNC` 生产构建中存在 | `App/UsageDockApp.swift`（`#if TOKENREMAIN_CLOUD_SYNC`）；`script/build_and_run.sh` 仅在 `USAGEDOCK_SYNC_RELEASE=1` 时加 `-DTOKENREMAIN_CLOUD_SYNC` | 2026-09-28 |

## Windows

| 事实 | 来源 | 核实日期 |
| --- | --- | --- |
| Windows 版在 `windows/`，与 macOS 同在 `main` 干线开发；CI 重新生成 locales 与图标必须零 diff | `.github/workflows/windows-validation.yml`；PR #41 | 2026-09-28 |
| 字体栈（含 `--mono`）必须显式带 `"Microsoft YaHei UI", "Microsoft YaHei"`，否则 Chromium 在 Windows 上把等宽栈的中文回退成宋体 | `windows/src/theme.css` | 2026-09-28 |
| 玻璃窗口配方：`transparent: false` + `backgroundColor: "#00000000"` + `backgroundMaterial: "acrylic"`，圆角与去边框用 koffi 调 DWM（`DWMWA_WINDOW_CORNER_PREFERENCE = 33`）；`backgroundMaterial` 建窗即锁定；透明窗（悬浮窗）里任何 `backdrop-filter` 都会渲染成黑块 | `windows/electron/main.js`、`windows/electron/windows-chrome.js`、`windows/src/floating.css` 注释 | 2026-09-28 |
| 渲染层有三个 HTML 入口：`index.html`（Dashboard）、`popover.html`（托盘弹窗，布局语义在 `src/popover-layout.js`，镜像 macOS `PopoverLayoutStore`）、`floating.html`（悬浮窗）；`index.html` 与 `popover.html` 的 CSP 为 `connect-src 'none'`，会拦 vite HMR websocket | `windows/*.html`、`windows/src/` | 2026-09-28 |

## 网站与素材

| 事实 | 来源 | 核实日期 |
| --- | --- | --- |
| 对外产品名一律是 TokenRemain，UsageDock 只是内部工程代号；仓库名 `token-remain`，下载文件 `TokenRemain.dmg`，官网经 `api.tokenremain.com/v1/downloads/macos` 跳转到 GitHub 最新发布 | `script/verify_website_release_contract.sh`；`site/*.html` 中无 “UsageDock” | 2026-09-28 |
| 官网截图按语言分两套：默认文件名是英文，中文加 `-zh` 后缀；`<img>` 用 `data-shot-en` / `data-shot-zh` 声明，`applyShots()` 按语言切换；新截图必须带 `data-shot-en` 才会被扫描 | `site/index.html`、`site/assets/` | 2026-09-28 |
| 重拍桌面截图可用启动参数直达表面：`--open-dashboard`、`--open-popover`、`--open-section <rawValue>`，配合 `-AppleLanguages "(en)"` 切语言（应用没有内置语言开关）；启动和驱动应用是 D 级操作，需任务授权 | `App/UsageDockApp.swift` | 2026-09-28 |

## 产品定位与设计约定

这些是项目所有者对产品的决定，不是个人习惯；新方案与之冲突时先向用户确认。

| 约定 | 来源 | 核实日期 |
| --- | --- | --- |
| TokenRemain 是轻量额度监控，不做数据分析平台；菜单栏保持百分比极简；自定义区间、聚合指标、多维明细等需求如确有必要，做成解耦的独立分析包 | issue #42、#44 的处理（2026-08-26） | 2026-09-28 |
| 不接入第三方社区的重置概率预测（codexradar 已于 2026-07-20 移除）；若做重置预测，走本地记录官方事件的自研路线 | 代码中已无 codexradar 引用 | 2026-09-28 |
| 品牌紫/青只表达身份；状态语义保持 success `#57D19A` / warning `#FFB554` / danger `#FF6B6B`，并始终配符号与文字标签 | `Views/Theme/DashboardTheme.swift`、`design/palette.md`、`ThemeContrastTests` | 2026-09-28 |
| provider 身份色统一为低饱和、同明度的色带（如 Claude `#BF8471`）；官方 logo 色不变；背景保持中性，语义卡只在徽章与描边着色 | `Views/Theme/DashboardTheme.swift` | 2026-09-28 |
| 能推断用户意图的组合操作直接完成，不用提示拦截；同屏品牌元素只出现一次；UI 只显示系统语言，不做双语装饰 | 桌面端评审记录（2026-07-20） | 2026-09-28 |
| 用户可见字符串全部走 `L10n.text` / `L10n.format` 语义 key；回退链为当前语言 → en → 内置 fallback 字典（保证无 app bundle 的 SwiftPM 测试行为确定）；`FeedPriorityClassifier` 中的中文是内容分类关键词，不翻译 | `Support/L10n.swift`、`Support/FeedPriorityClassifier.swift`、`LocalizationTests` | 2026-09-28 |

## 工具链坑

| 事实 | 来源 | 核实日期 |
| --- | --- | --- |
| SwiftPM target 排除 `Resources` 与 `Localization`，lproj 由 `script/build_and_run.sh` 拷入 app bundle；所以 `swift test` 没有本地化 bundle，依赖 L10n 内置 fallback | `Package.swift`、`Support/L10n.swift` | 2026-09-28 |
| Codex `workspace-write` sandbox 禁写 `.git`，默认不开网络；lane 或自动化在此设置下无法 commit、push、调用 `gh` | 见“宿主能力” | 2026-09-28 |
| 通过 hook 调用的护栏在 lane 中会拦下行首的禁止命令，包括 heredoc 正文里以这些命令开头的行；lane 写文件优先用宿主的文件写入工具 | `script/agent_lane_guard.sh` | 2026-09-28 |

## 待转为契约

按 R15，下列条目适合做成测试或脚本；落地后从上文删去对应文字，改为指向契约。

| 条目 | 建议的契约 | 现状 |
| --- | --- | --- |
| 多池不得在 primary 与 secondary 放相同 `windowMinutes` | 桌面侧测试：把各 provider fixture 经 `MobileSnapshotRedactor` 生成快照后走同步校验，断言不出现 `duplicateWindow` | 协议层已有 `SyncProtocolTests`，桌面侧缺端到端断言 |
| Windows 字体栈必须带微软雅黑 | `windows/tests` 中检查所有 `font-family` 与 `--mono` 声明都含 `Microsoft YaHei` | 未实现 |
| 透明 Electron 窗不得使用 `backdrop-filter` | 对 `floating.css` 的静态检查 | 只有注释 |
| 官网每张截图都有中英两套 | 在 `verify_website_release_contract.sh` 中检查每个 `data-shot-en` 都有对应的 `data-shot-zh` 且文件存在 | 未实现 |
| 对外内容不出现 UsageDock | 在官网契约脚本中 grep `site/` | 当前为 0 处，未设检查 |
| 状态色与徽章文字对比度 | 已有 `ThemeContrastTests`（状态色 3:1）；可补“填充徽章上的墨色文字” | 部分已是契约 |
| 新 `settings.pool_*` 键七语齐全 | 已由 `LocalizationTests.fullyLocalizedLocales` 保证 | 已是契约 |
