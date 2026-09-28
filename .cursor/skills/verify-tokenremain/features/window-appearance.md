# 窗口与外观

用户打开和关闭 Dashboard 与菜单栏弹窗，切换外观或尺寸状态；窗口按目标状态显示，重复操作没有可见回归。

**状态：** `draft`

## Sub-features

- `window-open-close`：Dashboard 与菜单栏弹窗可反复打开和关闭。
- `appearance-switch`：按任务目标切换外观或尺寸状态，显示与设置一致。

## How to get to it (user POV)

- 点击菜单栏图标打开弹窗；从弹窗或启动参数 `--open-dashboard` 打开 Dashboard。
- 在设置中切换外观或尺寸相关选项。

## Driving it with native macOS control

Preconditions:

- 已完成 Doctor 与授权的 Launch。
- 操作前保存将要改动的偏好（包括原先不存在的情况）。

- **打开与关闭。** 打开、关闭 Dashboard 与弹窗，重复至少一次，记录操作前后的窗口状态。
- **切换。** 按任务目标切换外观或尺寸状态，记录切换前后的显示。
- **恢复。** 结束时恢复保存的偏好，并核对恢复结果。

## Gotchas

- 检查隐藏状态、尺寸反馈及可见回归。
- 卡片与滚动按 [DB-002](../../../../docs/design-boundaries.md#db-002) 验证最窄宽度、较长文案、常见内容完整呈现、整页滚动及真实溢出。
- 玻璃偏好在 Dev 与生产使用不同的 defaults 域，对比前先分别读取。
