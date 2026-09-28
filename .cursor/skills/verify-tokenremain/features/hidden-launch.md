# 隐藏启动

用户让 TokenRemain 只留在菜单栏、不打开任何窗口时，应用保持存活，后台刷新不会顺带创建 Dashboard 或弹窗面板。issue #34 的崩溃就发生在这条无交互路径上。

**状态：** `verified @ 2026-09-28 74a1367 macOS 26.6.2 (25G83)`

## Sub-features

- `hidden-idle`：以 `--menu-bar-only` 启动后保持不交互，进程存活，没有意外的 Dashboard 或面板窗口。
- `hidden-no-crash`：等待期间没有新增该进程的崩溃报告。
- `launch-stability`：`script/verify_launch_stability.sh` 按两种玻璃各跑多轮无交互启动。

## How to get to it (user POV)

- 用户关闭所有窗口，让应用留在菜单栏。验证时用 Dev 实例的 `--menu-bar-only` 启动参数进入同一状态；`Sources/UsageDock/App/UsageDockApp.swift` 在该参数下不创建 Dashboard。

## Driving it with native macOS control

Preconditions:

- 已完成 SKILL.md 的 Doctor；本次 D 级运行已授权，没有其他 `UsageDockDev` 实例，或已取得明确协调结果。
- 被测产物是本任务构建并安装的 `TokenRemain Dev.app`，发布环境变量已排除。

- **启动。** 以菜单栏模式启动 Dev 实例：`/usr/bin/open -a "<Dev app 路径>" --args --menu-bar-only`。记录 PID、可执行路径和被测源码指纹。
- **保持不交互。** 不点击菜单栏图标、不打开窗口，至少等待 90 秒（与稳定性脚本一轮相同）。
- **窗口。** 用宿主的原生控制能力列出该 PID 的窗口。期望没有 Dashboard 或弹窗面板窗口。
- **存活。** `ps -p <PID> -o comm=` 仍返回 Dev 可执行文件。
- **崩溃报告。** `~/Library/Logs/DiagnosticReports` 中启动时间之后没有新增 `UsageDockDev` 报告。
- **启动稳定性。** 可用 `bash script/verify_launch_stability.sh`，但必须满足上面的独占条件，提前保存玻璃偏好是否存在、值及类型，并保证成功/失败后恢复。脚本默认每种玻璃两轮、每轮 90 秒；缩短只算 smoke，不替代原强度。旧系统可能输出 skipped 并退出 0，仍然是跳过。`--skip-build` 的现有指纹覆盖并不包含所有资源与共享包；涉及这些变更时重新构建并另外记录来源，不单靠 stamp。

## Gotchas

- macOS 26 玻璃路径需要该系统；不能仅以启动瞬间截图验收。
- 该崩溃不是每次触发（稳定性脚本注释记录了 5–8 秒与 37 秒两种复现时长），单轮通过是证据，不是证明。
- `build_and_run.sh --verify` 只检查进程存在，不能证明隐藏状态正确。
- `verify_launch_stability.sh` 会按名字停止进程并修改玻璃偏好，只在证明独占后使用。

**实跑记录（2026-09-28）。** 覆盖 `hidden-idle` 与 `hidden-no-crash`；`launch-stability` 未运行，仍未验证。被测源码为 `74a1367`，产品代码与 `origin/main` 的 `c30f66f` 相同；arm64。以 `USAGEDOCK_INSTALL_DIR=<任务临时目录> bash script/build_and_run.sh run` 构建安装（未替换 `~/Applications` 下已安装的 Dev 应用），该模式会先正常启动一次，此实例按 PID 停止后再以 `--menu-bar-only` 启动。启动前无 `UsageDockDev` 实例、无 `USAGEDOCK_*` 环境变量。结果：+3 秒与 +98 秒时进程都存活，只拥有 4 个不在屏幕上的 1512×33 菜单栏尺寸窗口，没有 Dashboard 或弹窗面板窗口（CoreGraphics 窗口列表按 PID 过滤）；无新增 `UsageDockDev` 崩溃报告；运行中的生产实例未受影响。清理：只停止本次 PID，Dev 偏好导出前后无差异，任务安装目录已注销并删除。原始证据保存在该任务的临时目录，未入库。
