# 窗口与外观

用户打开和关闭 Dashboard 与菜单栏弹窗，切换外观或尺寸状态；窗口按目标状态显示，重复操作没有可见回归。

**状态：** `draft`

## Sub-features

- `window-open-close`：Dashboard 与菜单栏弹窗可反复打开和关闭。
- `appearance-switch`：按任务目标切换外观或尺寸状态，显示与设置一致。
- `layout-stability`：滚动 Dashboard 页面、反复缩放窗口时，应用的 CPU 和内存在停止操作后恢复平稳。

## How to get to it (user POV)

- 点击菜单栏图标打开弹窗；从弹窗或启动参数 `--open-dashboard` 打开 Dashboard。
- 在设置中切换外观或尺寸相关选项。

## Driving it with native macOS control

Preconditions:

- 已完成 Doctor 与授权的 Launch。
- 操作前保存将要改动的偏好（包括原先不存在的情况）。

- **打开与关闭。** 打开、关闭 Dashboard 与弹窗，重复至少一次，记录操作前后的窗口状态。
- **切换。** 按任务目标切换外观或尺寸状态，记录切换前后的显示。
- **布局稳定。** 改动测量点、网格或滚动结构时执行。先记录 Dev 实例 PID，用 `swift script/measure_process_energy.swift --pid <pid> --duration 10 --samples 3` 和 `ps -o rss= -p <pid>` 采集空闲基线。在 Limits 等改动页面上下滚动到底再回顶，重复三轮；再拖动 Dashboard 窗口宽度，跨过单列、两列、三列断点，同样重复三轮。操作期间和停止后各采样一次。通过标准：停止操作后 CPU 回到基线附近，界面能继续响应；三轮之后常驻内存没有持续增长。主线程持续高 CPU 或内存逐轮上涨，都算失败。
- **恢复。** 结束时恢复保存的偏好，并核对恢复结果。

## Gotchas

- 检查隐藏状态、尺寸反馈及可见回归。
- 测量反馈循环不一定每次都出现：1.4.7 (46) 只在部分 Dashboard 数据下、滚动时才卡死。用尽量接近真实的 provider 数量和多账号状态操作，只用一张截图或一次短滚动不能判定通过。`script/verify_layout_measurement_contract.sh` 只检查测量点登记情况，不能代替这项检查。
- 卡片与滚动按 [DB-002](../../../../docs/design-boundaries.md#db-002) 验证最窄宽度、较长文案、常见内容完整呈现、整页滚动及真实溢出。
- 玻璃偏好在 Dev 与生产使用不同的 defaults 域，对比前先分别读取。
