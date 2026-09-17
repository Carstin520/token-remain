# Issue #57：百炼 Token Plan 接入

## 开发流程与范围

1. 固定基线、确认用户授权：在 `codex/v1.3.9` 开发；保留已有 Devices / CHANGELOG 修改。本任务不提交、推送、合并或发布。
2. 核实协议、账号归属、单位、地域和副作用。
3. 填写 DB-001 / DB-002 设计决策，确认持久化与同步消费者。
4. 用虚构 fixture 建立失败用例，先复现 Token Plan 被错误识别为通用 JSON 来源。
5. 实现专用 Provider、受控网络读取、明确的设置入口与路由提示。
6. 运行定向、全量和同步编译路径测试，再检查隔离的原生界面。
7. 审查任务 diff、原有文件哈希、错误与写入路径；报告真实账号未验证项。

首轮工作预算 90 分钟；同一路径无新证据连续失败三次即换路。任务证据保存在临时目录。

## 协议事实与本次范围

- [Issue #57](https://github.com/Carstin520/token-remain/issues/57) 的实际问题是团队版额度不能通过调用模型的 API Key 或通用 Bearer JSON 适配器读取。
- [官方 CLI 命令源码](https://github.com/modelstudioai/cli/blob/main/packages/commands/src/commands/usage/token-plan.ts) 查询 `/tokenplan/personal/api/v2/usage`，返回个人版 5 小时/7 天用量比率，不能当作团队 Credits 的支持证明。
- [官方网关源码](https://github.com/modelstudioai/cli/blob/main/packages/core/src/console/gateway.ts) 确认个人版地域网关及参数封装。
- [CodexBar 协议参考](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Alibaba/AlibabaTokenPlanUsageFetcher.swift) 与同目录 APIRegion、PersonalUsageParser、其测试用于核对控制台请求和字段。实现独立编写；不移植浏览器导入或 CLI 执行器。

本次实现 macOS 专用 Provider：国内/国际、团队/个人，用户主动粘贴 Cookie；地域和套餐与 Cookie 作为同一配置，在验证成功后一起保存于应用自己的 Keychain 条目。使用现有保存、替换、清除和授权能力。

CLI 与浏览器自动导入留作后续独立范围；本次不调用第三方认证命令、不扫描浏览器、不刷新会话、不改变第三方凭证。个人版只查询额度所需接口，暂不增加套餐档位查询和可选元数据请求。

### 账号与数值合同

- Token Plan 精确域名识别，不能将所有 `aliyuncs.com` 服务归入 Token Plan。
- Claude/Codex/OpenCode 路由 API Key 与 Cookie 无可验证的账号绑定：提示用户添加独立 Token Plan 卡片，不用全局 Cookie 冒充路由账号。
- 团队展示 Credits 总池的剩余数量及使用百分比，采用独立计数字段，不冒充货币余额。无有效总量/剩余量即明确失败；不跨多个未知子池拼凑数据。
- 个人版比率乘 100；5 小时、7 天独立存在，缺失窗口不伪造为 0% 使用。无窗口时提示暂不可用。
- 只把明确的周期结束/重置字段解释为 reset；`NearestExpireDate` 是到期时间，不能直接冒充额度重置。
- 新的可选 Credits 字段兼容旧 macOS 缓存解码；新 provider 暂不进入已发布移动端白名单，不修改共享 wire schema 或其他仓库。

## DB-001：等待、取消、恢复

- 所有者：专用 service 只返回快照；UsageStore 验证后保存，界面复用 AsyncViewAction。
- 总预算 30 秒：最多一次控制台页面读取（补取请求所需的 sec_token）和一次额度查询；每次请求 12 秒。适用于短只读操作，不继承 90 秒通用上限作为设计默认。不自动重试。
- 请求仅固定 HTTPS 主机，禁止重定向；无 Cookie 持久存储、无 URL 缓存、无 Set-Cookie 写回。临时 sec_token 仅用于当前请求，不保存。
- 成功：停止等待并保存新凭证/快照。失败：停止等待、显示脱敏错误、可重试；验证失败不替换旧凭证。
- 超时/取消：传到 URLSession，停止等待，旧快照保留原 capturedAt；不宣称凭证无效。视图离开取消保存，切换地域/套餐不立即写入或请求。
- 只读请求无外部写操作待确认；本地提交前核对取消，迟到结果不得保存。取消后重试沿用现有操作身份隔离。
- 用注入 transport 测试请求、错误、取消、迟到响应；Store 测试所有缓存、Keychain 写入均为替身或临时目录。

## DB-002：简洁 UI

- 复用现有额度卡、Data Sources 安全输入框；两个紧凑选择器（地域、套餐），不新增页面、JSON 编辑器或折叠状态机。
- 常见内容：团队一行 Credits；个人两行额度、各自重置时间、配速与更新时间。保持现有卡片基础高度，按真实文本自然布局。
- 核对窄宽度、中文/英文、提示与保存状态，常见两窗口不制造内层滚动。

## 验收

- 路由识别与假域名、账号归属防串号。
- 四种请求的固定主机、ProductCode/网关封装、Cookie/CSRF、重定向禁用与脱敏。
- 团队、个人、单窗口、0 剩余、缺字段、字符串封装、嵌套错误、非有限数/布尔值、错误套餐及到期不冒充重置。
- 取消/超时/迟到结果、重试与旧凭证不覆盖；默认模拟不读取真实凭证。
- macOS 全量测试、同步编译路径及同步白名单回归、本地化完整性检查（仅 macOS 接入，不更新 Windows 生成文件）。
- 原生展示与真实百炼联调分别报告；没有用户账号时不宣称真实认证和额度数值已验收，不自动关闭 issue。

## 实现与验证记录

- 核心读取实现：`AlibabaTokenPlanUsageService.swift`，无 CLI / 浏览器凭证扫描，固定地域网关、Cookie/CSRF、仅当前读取的页面 nonce。
- UI 短名 `Bailian`，持久化 provider 身份为 `Alibaba Token Plan`；新增资源沿用仓库现有 Lobe Icons 1.94.0 来源。
- 发现并补齐凭证替换竞态：验证开始与提交成功时都更新版本，后台读取、手动刷新、旧验证和授权结果必须匹配当前版本，防止验证期间启动的旧账号读取在提交后覆盖数据。
- 旧 Devices 页面改动哈希保持不变，CHANGELOG 原有删除 Direct Sync 条目保留。
- 已完成普通/同步模式全量回归；均有 3 项需要特定真实 Keychain ACL 环境的测试按既有条件跳过。独立的后台非交互读取脚本通过。
- 隔离原生预览：300 pt 英文/中文/德文，个人两窗口完整展示；德文较长内容自然撑高；卡片区域滚轮推动整页滚动。团队 Credits 换行时仍完整可读。
- 原生等待路径：模拟 3 秒及 12 秒预算观察超时退出，主动取消恢复控件，后续成功重试；使用测试专用目录、偏好域和所有缓存，凭证写入为空操作。产品读取预算仍是 30 秒。
- 本次没有真实百炼账号联调证据。团队/个人及地域请求均由公开协议资料和虚构 fixture 验证；内部控制台接口可能变化，不能据此自动关闭 issue 或声称真实额度准确性已验收。
- 本次未做 CLI、自动浏览器 Cookie 导入、Windows 或移动端 Provider 支持；新 provider 不进入现有同步白名单。

- Dev 1.3.9 (36) 已构建安装并通过签名检查，真实 Limits 添加菜单可见 Bailian；生产版文件哈希与 PID 均未变化。
