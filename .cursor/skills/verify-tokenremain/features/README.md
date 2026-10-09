# TokenRemain 原生验证功能地图

本目录是 TokenRemain macOS 应用用户可见行为的验证来源。驱动应用前先读 [verify-tokenremain](../SKILL.md) 的 Doctor、Launch 与 Evidence/Cleanup，再打开对应功能文件。地图只写用户路径、稳定入口、所需状态和可观察证据，不写实现细节。

## 基线前提

- 只驱动本次运行启动、且 Doctor 确认归属的 Dev 实例（`TokenRemain Dev` / `UsageDockDev` / `com.jamesli.usagedock.dev`）；不驱动生产 `TokenRemain.app` 或他人的 Dev 实例。
- D 级运行须有任务授权并证明实例独占（AGENTS.md R8）；无人值守 lane 不做 D 级运行（R14）。
- 操作前保存会改动的偏好（包括原先不存在的情况），结束后恢复。

## 状态标注

每个功能文件在第一段后写一行状态：

- `draft`：配方从未端到端实跑。
- `verified @ <YYYY-MM-DD> <HEAD 短 SHA> <macOS 版本与 build>`：该功能在这些条件下实跑过一次，证据位置写在同一文件的 Gotchas 之后。它不证明其他功能，也不证明之后的提交。

## 功能条目合同

每个功能文件以 H1 标题和一段用户可见行为描述开头，随后是状态行，再按顺序使用四个 H2：`Sub-features`、`How to get to it (user POV)`、`Driving it with native macOS control`、`Gotchas`。驱动步骤以 `Preconditions:` 开头，每一步把用户动作、命令或操作与可观察结果配对。

## 功能

- [隐藏启动](hidden-launch.md) 覆盖菜单栏模式无交互启动、存活、无意外窗口和启动稳定性脚本。
- [额度与刷新](quota-refresh.md) 覆盖弹窗与 Dashboard 中的额度展示和用户触发的刷新。
- [登录/凭证等待](login-wait.md) 覆盖等待、取消、超时、控件恢复、重试和迟到结果。
- [窗口与外观](window-appearance.md) 覆盖 Dashboard、菜单栏弹窗的打开关闭和外观/尺寸切换。
- [同步](sync.md) 覆盖源端展示 DTO 与消费端显示的比较。
