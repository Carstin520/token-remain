---
name: verify-tokenremain
description: 为 TokenRemain 改动按模块与实际副作用选择静态检查、SwiftPM/Windows/Worker 测试及原生运行验证，记录可复核证据。用于验证修复或验收；安装、真实账号操作与发布依任务授权执行。
---

# TokenRemain 验证入口

先读 [AGENTS.md](../../../AGENTS.md)，尤其 R3、R4、R8、R9、R12、R13。以下路径和命令相对仓库根目录；执行前确认工作目录，检查当前脚本与环境，不能把历史命令列表当作永久安全白名单。

**状态：验证路由与脚本行为已按 2026-09-05 源码检查；原生 UI 驱动配方尚未端到端实测，属于草稿。** 不得将其描述为已通过的自动化 UI harness。首次实跑一条功能后，记录环境、动作、结果、清理和仍存在的证据，再在明确规则维护任务中更新该路径状态；一个功能通过不代表所有功能通过。

初次编写时实际执行了 `verify_keychain_read_contract.sh` 和 `verify_launch_surface_isolation.sh`，均通过。这只记录当时的静态契约结果，不是未来任务的通过凭证，也不代表完整测试或运行验收。

## 1. 确认对象与副作用

记录 HEAD、任务相关未提交 diff、OS/架构、工具链、被测产物来源和完成条件。证据放在本任务拥有的临时目录，记录绝对路径并在清理后保留；不自动写入历史 `reports/` 或提交日志。原始账号数据先脱敏。

| 等级 | 行为与准入 |
| --- | --- |
| S：源代码检查 | 读取源码或创建自己的临时文件，不安装/启动应用，不读取真实凭证。按任务需要直接执行 |
| T：测试/构建 | 写构建缓存、测试临时状态；依赖缺失时可能联网。检查测试的 opt-in 开关和真实服务依赖，不自动升级依赖或启用 live credential probe |
| D：原生/集成运行 | 安装、签名、停止或启动应用、修改偏好、调用真实服务。必须已有相应运行授权且证明实例与状态归属；不能默认打断用户 Dev 实例 |
| P：发布/生产操作 | 发布签名/公证上传、公开产物、部署或生产数据操作。按具体任务授权和发布流程执行，不能由验证自动升级到此等级 |

等级不是“必须逐级执行”。文案检查可止于 S；源代码测试不能冒充 D；D 也不能冒充 P。请求“运行 Dev 应用验证”已包含相应授权时不要重复询问，但仍须核实不会影响其他实例。

## 2. 按修改范围选检查

| 改动 | 最小相关入口 | 需要扩大的情况 |
| --- | --- | --- |
| 文档、规则、技能 | 检查 frontmatter、相对链接、路径、命令副作用和 diff；不为此构建应用 | 修改了验证配方时，只在可安全运行的范围内实跑，其他路径保留草稿状态 |
| Provider/PTY | 发现对应 `Tests/UsageDockTests/` suite；重放已脱敏 `Fixtures/`；凭证路径加 Keychain 契约脚本 | 共享采集/缓存/账号路径变化扩大到相关消费者；真实 provider 状态需另做 D 验证 |
| 刷新/共享 Store | 定向策略、缓存、通知测试；共享核心变化再跑完整 macOS suite | 比较用户设置、活跃/空闲/退避/过期状态；性能结论需要同条件实测 |
| 同步 | SyncKit suite；桌面 Redactor/Fingerprint/DirectSync 相关测试；变更编译条件时检查对应构建 | 协议变更补旧 payload、新 payload、过期/重放/脱敏；跨端验收需要实际消费者证据 |
| macOS UI/启动 | 相关布局/启动契约；卡片与滚动按 [DB-002](../../../docs/design-boundaries.md#db-002) 检查，不新增只断言尺寸常量的测试 | D 级验证最窄宽度、较长文案、常见内容完整呈现、整页滚动及真实溢出；隐藏启动与 macOS 26 路径分别取证 |
| 登录/授权/异步等待 | 按 [DB-001](../../../docs/design-boundaries.md#db-001) 定向覆盖不返回、取消、超时、迟到结果、重试和部分完成 | 共享等待工具扩大相关 suite；交互变化补 D 级“等待 → 退出 → 恢复 → 重试”，模拟与真实账号证据分开 |
| Windows | 在 `windows/` 运行 `npm run check` | 原生 Keychain 替代机制、托盘、窗口和安装行为需要 Windows runner/设备；检查 CI 实际 commit |
| 官网/broadcast | 在各自目录运行 `npm run check`，先检查脚本 | 浏览器/API 行为按任务补充；check 中的 Wrangler dry-run 不是生产部署 |
| 发布相关 | 版本、更新、bundled helper 等独立契约按需选择 | 完整 suite、分发签名产物和授权的公开发布证据；不能跳过现有发布门禁 |

本地化影响 Windows 时先检查 `windows/scripts/generate-locales.mjs`，在拥有对应输出改动的条件下运行 `npm --prefix windows run locales:generate`。图标同理使用 `icon:generate`。二者会写生成文件，不能列作 S 级只读检查。不要把用户尚未提交的其他本地化/资产改动顺带生成进本任务。

## 3. S 级入口

以下脚本在初始源码检查中只读项目内容，或仅创建/删除自己生成的临时文件。只挑任务相关项；不能将多个脚本通过合称为应用已验证。

```bash
bash script/verify_keychain_read_contract.sh
bash script/verify_launch_surface_isolation.sh
bash script/verify_version_consistency.sh
bash script/verify_automatic_update_contract.sh
```

变更 shell 脚本可用 `bash -n` 检查其语法；该检查不执行脚本，也不证明行为。

**不得直接归为 S 的现有入口：**

- `verify_release_configuration.sh` 调用 `verify_ccusage_freshness.sh --update`，可联网并改 `Vendor/`、版本相关配置。仅在授权范围包含该更新时运行；无授权时运行适用的独立门禁并明确完整发布门禁未完成。
- `build_and_run.sh --verify` 会停止进程、签名、安装、启动；结尾只检查进程存在，不能证明目标功能正确。
- `build_and_run.sh --print-install-contract` 的 EXIT trap 会清理对应 `dist/` bundle。`verify_installation_isolation.sh` 会调用 Dev 和 sync 两种 contract；只在确认对应暂存产物可清理的受控范围内使用，否则直接读代码检查。
- `verify_launch_stability.sh` 会构建/安装、按名字停进程、改玻璃偏好。`--skip-build` 仍会改变运行状态；默认结束删除偏好值，并不恢复用户原值。
- `verify_ccusage_freshness.sh --local` 还会执行本地 helper，`--check` 会联网；先检查当前实现，不凭参数名归为静态检查。

## 4. T 级入口

模拟网络、CLI 或凭证验证前，追踪真实提交点及间接写入，确认凭证、偏好、账号目录、额度缓存、历史和派生缓存全部使用测试自己的目录/命名空间或替身。仅替换请求、设置 `automaticallyStarts: false` 或使用独立 worktree 不足以证明隔离；按风险核对真实状态未被测试写入。

先用源码发现实际 suite 名称，例如 `rg -n '@Suite|struct .*Tests|class .*Tests' Tests/UsageDockTests`。定向执行 `swift test --filter` 时填写真实 suite，确认输出确实运行了目标测试；匹配到零测试不算通过。

在此机器可先检查 `/Applications/Xcode.app/Contents/Developer` 是否存在；需要指定工具链时将 `DEVELOPER_DIR` 设为它。发生模块缓存权限错误时，将 `SWIFTPM_MODULECACHE_OVERRIDE` 和 `CLANG_MODULE_CACHE_PATH` 指向各自任务临时目录。多个 SwiftPM 进程不要共写同一构建目录。

完整测试入口按影响范围选择：

```bash
swift test --no-parallel
swift test --package-path Packages/TokenRemainSyncKit --no-parallel
npm --prefix windows run check
npm --prefix site run check
npm --prefix broadcast run check
```

上面不是要求每个任务全部执行。现有 SwiftPM 环境确因 package sandbox 阻断必要操作，且宿主允许时才增加 `--disable-sandbox`；不把它当作绕过宿主权限的方法。修改 `TOKENREMAIN_CLOUD_SYNC` 条件路径时，在同样隔离条件下补 `swift test --no-parallel -Xswiftc -DTOKENREMAIN_CLOUD_SYNC`；这不能证明 CloudKit 生产连接或发布签名有效。

`npm run check` 会写构建输出，Wrangler dry-run 可能使用本地缓存或网络；先确认当前 package scripts。依赖安装仅用对应锁文件，不顺便更新 lockfile/版本。不能在 macOS 上把 Windows renderer build 通过称为 Windows 原生验收。

遇到 socket、Keychain 或其他环境相关失败时保留原始结果，做有针对性的复查；非并行通过与初次完整 suite 失败分别报告，不能把历史故障直接当作当前失败的解释。

## 5. D 级原生验证配方（草稿）

### Doctor：启动前检查

只读取当前 OS、进程参数/可执行路径、目标 bundle 的 Info.plist 与签名状态，核对任务的构建来源。记录用户已运行的生产与 Dev 实例，不能只凭 `pgrep` 同名命中认领进程。

检查实际 `USAGEDOCK_*` 构建环境，防止继承 sync 发布、provisioning 或生产签名选项。普通开发身份应为 `TokenRemain Dev` / `UsageDockDev` / `com.jamesli.usagedock.dev`；具体路径以当前脚本为准。仅更改安装目录无法隔离相同进程名和偏好域。若有其他同名 Dev 实例，先取得明确协调结果或留待运行验证，不执行会按名字杀进程的脚本。

### Launch：仅在授权且独占实例后执行

在无其他 Dev 实例、安装目标属于任务且发布环境已排除的条件下，现有入口是：

```bash
bash script/build_and_run.sh --verify
```

记录被测源码指纹（包括未提交改动）、产物路径、版本、bundle ID、进程 PID 与可执行路径。进程仍在只是启动证据。不要启动第二个生产 CloudKit publisher，也不为方便 UI 自动登录或刷新凭证。

### Drive：按真实用户路径选择功能

使用当前宿主实际提供的原生 macOS 控制能力，先观察可访问性树/屏幕再选择按钮，不编造 selector 或照抄坐标。仅有浏览器工具时无法据此验证 AppKit，标记对应路径未验证。

| 功能 | 用户路径与可观察结果 | 边界 |
| --- | --- | --- |
| 隐藏启动 | 经授权在 Dev 实例运行 `--menu-bar-only`，保持不交互；核对没有意外 Dashboard/面板创建、进程存活及新增崩溃报告 | macOS 26 玻璃路径需该系统；不能仅以启动瞬间截图验收 |
| 额度与刷新 | 打开菜单栏弹窗或 Dashboard，观察已配置 provider；仅在真实查询已授权时触发用户刷新，比较额度、池、时间与状态 | 不改账号、登录或绕过 Keychain；截图先脱敏，fixture 结果与真实请求分开 |
| 登录/凭证等待 | 在隔离请求或已授权真实流程中观察等待、取消/超时、提示、控件恢复和再次尝试；核对迟到结果未提交 | 按 DB-001 区分取消与结果待确认；系统弹窗未被实际关闭时不声称已终止；不为模拟验收写入真实凭证或缓存 |
| 窗口与外观 | 打开/关闭 Dashboard、菜单栏弹窗，按目标修改切换外观或尺寸状态，记录操作前后和重复交互 | 检查隐藏状态、尺寸反馈及可见回归；操作前保存偏好，结束恢复 |
| 同步 | 仅在已有授权和对应构建/设备下，比较源端展示 DTO 与消费端显示及序列/时间状态 | 普通 Dev 不证明生产 CloudKit；无消费者只报告本地协议测试 |

启动稳定性可用 `bash script/verify_launch_stability.sh`，但必须满足上面的独占条件，提前保存玻璃偏好是否存在、值及类型，并保证成功/失败后恢复。脚本默认每种玻璃两轮、每轮 90 秒；缩短只算 smoke，不替代原强度。旧系统可能输出 skipped 并退出 0，仍然是跳过。`--skip-build` 的现有指纹覆盖并不包含所有资源与共享包；涉及这些变更时重新构建并另外记录来源，不单靠 stamp。

### Evidence 与 Cleanup

保存动作及结果、必要截图/日志、退出码、OS/架构、源码与产物身份。只终止能由本次启动记录及当前可执行路径确认归属的 PID；不自行使用宽泛 `pkill`/`killall` 清理。现有脚本按进程名停止只在事先证明独占时允许使用。

恢复本任务改变的偏好（包括原先不存在的情况），清理任务自己的实例与临时状态；不删证据，不触碰生产应用、其他 worktree、Keychain 或用户缓存。不把签名后 bundle 内写文件当作证据存储。核对清理后证据仍存在，报告保留的 Dev 安装和任何未恢复状态。

## 6. 出具验证结果

逐项记录 `PASS / FAIL / SKIPPED / UNVERIFIED`，附命令、实际运行数量/条件、观察结果与证据路径；退出码 0 但输出 skipped 或零测试不是 PASS。区分源码检查、定向测试、完整 suite、原生行为、跨端与发布结果。下一步由缺口决定，不能自动升级到安装或生产操作。
