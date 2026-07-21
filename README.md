# UsageDock

macOS 菜单栏常驻用量助手，同时展示：

- Claude Code 官方 5 小时 / 7 天剩余额度与重置倒计时
- Codex 主账户实时 5 小时 / 7 天剩余额度（服务端接口直查，离线时回退最近本地快照）
- Cursor 月度账期剩余额度与重置倒计时（服务端接口直查）
- Grok（xAI）周池剩余额度（只读 Grok CLI 凭证直查）
- Z.ai GLM Coding Plan 会话 / 周窗口剩余额度（用户 API Key，存本机钥匙串）
- Copilot 月度 Credits（只读本机 GitHub 登录）、Devin 日/周配额、OpenRouter 预充积分（用户 API Key）、Antigravity 配额池（只读本机登录态）、OpenCode Go 套餐（本地数据库扫描估算，纯本地）
- 基于真实窗口进度与官方重置时间判断当前节奏能否持续到重置，并在可能提前用尽时给出预计可用时长
- ccusage 统计的 Claude Code / Codex 今日 token 与估算 API 成本
- AI Feed 聚合 Tibor Blaho、Sam Altman、Claude、Anthropic、OpenAI 与 Elon Musk 的 X 动态
- 自动置顶 Token / 额度重置和重大模型更新，并通过 macOS 本地通知提醒
- macOS 26 使用系统 Liquid Glass、原生侧栏与玻璃按钮；macOS 14/15 自动回退到原有深色卡片样式

## 数据与隐私

- Claude 限额主路径为官方 oauth/usage 接口直查：只读 Claude Code 已有的 OAuth access token（`~/.claude/.credentials.json` 文件优先，钥匙串兜底），绝不刷新 token、绝不写回凭证，因此不会与 Claude Code 争用 refresh token 或触发第三方续期限流。凭证缺失、过期或被拒时自动降级为在隔离伪终端中执行 `/usage` 解析——探针会让 Claude Code 自行完成续期，下一轮直查即恢复。
- Codex 限额主路径为服务端实时接口直查：只读 `~/.codex/auth.json` 中 Codex CLI 已有的 access token（同样不续期、不写回），可同时拿到 5 小时与 7 天窗口。未登录或 token 过期时降级为 `~/.codex` 会话文件中的 rate-limit 快照；没有额外上传。
- Cursor 月度额度同样只读 Cursor IDE 自己维护的 access token（`state.vscdb` 只读查询，钥匙串兜底），绝不使用 refresh token 代刷——代刷可能触发认证服务器的轮换检测并危及 Cursor 的登录态。因此 Cursor 长时间未运行导致 token 过期时数据会暂停更新，卡片会保留最近数据并提示“打开一次 Cursor 应用即可恢复额度刷新”。
- Grok（xAI）只读 `~/.grok/auth.json` 中 Grok CLI 已有的凭证查询周池额度，同样绝不代刷；凭证过期时提示“运行一次 grok 即可恢复”。
- Z.ai（GLM Coding Plan）是唯一需要手动接入的服务：在 Dashboard「数据源」页粘贴一次 API Key（也支持 `ZAI_API_KEY` 环境变量或 `~/.config/zai/key.json`），Key 仅保存在 macOS 钥匙串。
- 除 Z.ai 外全部自动接入：登录对应工具即自动读取本机凭证，无需任何配置；未接入的服务在额度卡片与「数据源」页显示具体接入指引。
- 首次启动有 onboarding：自动检测本机已安装的 AI 编码工具并预勾选，确认后开始追踪；之后在「额度」页可随时增删——「添加应用」卡片加入新服务，卡片右键停止追踪。选择保存在本地，菜单栏与弹窗同步跟随。
- ccusage 通过 `npx --yes ccusage@latest` 读取本地日志。成本是 API 标价估算，不等于订阅账单。
- Claude 限额成功读取后会缓存到 `~/Library/Caches/com.jamesli.usagedock/`；Claude Code 暂时不可用时继续显示最近有效值。
- 打开菜单栏面板会触发一次非阻塞的轻量刷新；刷新按钮则会立即刷新 ccusage、Codex 与 Claude。UsageDock 不会自行调用 Claude OAuth 续期接口，因此不会与 Claude Code 争用 refresh token 或触发第三方续期限流。
- AI Feed 使用用户自己的 X API Bearer Token；Token 仅保存在 macOS 钥匙串。公开帖子快照和已读 ID 缓存在本机，不写入日志。

## AI Feed

Dashboard 的 `AI Feed` 页面通过 X 官方 Recent Search API 聚合关注账号最近七天的公开原创帖子，每十分钟检查一次。首次连接只建立已读基线，不会把历史帖子一次性推送；之后新出现的额度重置、速率限制变化、重大模型发布、API 弃用或价格调整会置顶并触发系统通知。

X API 当前为按量计费服务。本地工程入口是 `Config/UsageDockFeed.local.plist`：

```xml
<key>XBearerToken</key>
<string>在这里填写你的 Bearer Token</string>
```

该文件已被 Git 忽略。执行 `bash ./script/build_and_run.sh --verify` 时，构建脚本只把配置文件路径传给已签名的 UsageDock；应用读取 Token 后写入自己的 macOS 钥匙串。Token 不会进入源码、应用包或命令行参数。AI Feed 页面中的安全输入框仍作为手动备用入口。

产品化切换入口是 `Sources/UsageDock/Configuration/FeedConfiguration.swift`。将 delivery 从 `.directXAPI` 改为 `.curatedAPI(endpoint: ...)` 后，客户端只读取 UsageDock 服务端筛选好的内容，不再接触 X API Token。完整接口与 APNs 数据契约见 `docs/curated-feed-contract.md`。

## 本地运行

```bash
bash ./script/build_and_run.sh --verify
```

应用为菜单栏专用，因此不会显示 Dock 图标。顶部栏使用 Claude / OpenAI 图标，所有百分比和进度条均表示剩余额度。Codex 快照每分钟检查一次；Claude 官方额度与 ccusage 每五分钟更新一次。

菜单栏展开面板内提供“登录时自动启动”开关，使用 macOS 原生登录项管理；旧版 LaunchAgent 不再使用。

## 当前安装位置

- 应用：`~/Applications/UsageDock.app`
- 登录启动：默认关闭，可在菜单中按需打开

# token-remain
