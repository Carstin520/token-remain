# 额度与刷新

用户打开菜单栏弹窗或 Dashboard，看到已配置 provider 的额度、额度池、重置时间和状态；需要最新数据时手动刷新。

**状态：** `draft`

## Sub-features

- `quota-view`：弹窗和 Dashboard 展示已配置 provider 的额度、池、时间与状态。
- `quota-refresh`：用户触发刷新后，额度、池、更新时间与状态按真实结果变化。

## How to get to it (user POV)

- 点击菜单栏图标打开弹窗。
- 打开 Dashboard；验证时可用 Dev 实例的 `--open-dashboard` 或 `--open-popover` 启动参数直接进入对应表面。

## Driving it with native macOS control

Preconditions:

- 已完成 Doctor 与授权的 Launch；只观察本机已配置的 provider。
- 触发真实查询须已有任务授权；否则只观察已有数据，并把刷新路径标为未验证。

- **观察。** 打开弹窗或 Dashboard，记录各 provider 的额度、池、时间与状态。截图先脱敏。
- **刷新。** 仅在真实查询已授权时触发用户刷新，比较刷新前后的额度、池、更新时间与状态。

## Gotchas

- 不改账号、不登录、不绕过 Keychain；后台读取必须保持非交互（R3）。
- fixture 结果与真实请求结果分开报告。
- 保留旧额度时不能伪造新的更新时间（DB-001）。
