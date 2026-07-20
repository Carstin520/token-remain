# UsageDock

macOS 菜单栏常驻用量助手，同时展示：

- Claude Code 官方 5 小时 / 7 天剩余额度与重置倒计时
- Codex 主账户最近服务端 rate-limit 快照；按服务端实际提供的窗口显示（当前可能只提供 7 天）
- 基于真实窗口进度与官方重置时间判断当前节奏能否持续到重置，并在可能提前用尽时给出预计可用时长
- ccusage 统计的 Claude Code / Codex 今日 token 与估算 API 成本
- AI Feed 聚合 Tibor Blaho、Sam Altman、Claude、Anthropic、OpenAI 与 Elon Musk 的 X 动态
- 自动置顶 Token / 额度重置和重大模型更新，并通过 macOS 本地通知提醒
- macOS 26 使用系统 Liquid Glass、原生侧栏与玻璃按钮；macOS 14/15 自动回退到原有深色卡片样式

## 数据与隐私

- UsageDock 不再读取或修改 Claude Code 的钥匙串凭证。Claude 限额由本机 Claude Code 在隔离的伪终端中执行 `/usage` 后解析；认证与 token 续期始终由 Claude Code 自己处理。
- Codex 数据来自 `~/.codex` 会话文件中的服务端 rate-limit 快照；没有额外上传。
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
