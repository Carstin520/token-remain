# 同步

用户在多台设备上看到一致的额度摘要：源端发布的展示 DTO 与消费端显示、序列号和时间状态一致。

**状态：** `draft`

## Sub-features

- `sync-publish`：源端展示 DTO 按脱敏白名单生成。
- `sync-consume`：消费端显示与源端 DTO、序列和时间状态一致。

## How to get to it (user POV)

- 在源端 Mac 上运行应用，在消费端（另一设备或客户端）查看同步结果。

## Driving it with native macOS control

Preconditions:

- 已有授权，并有对应的同步构建与消费端设备。

- **比较。** 比较源端展示 DTO 与消费端显示，以及序列号和时间状态。

## Gotchas

- 普通 Dev 构建不证明生产 CloudKit 连接。
- 没有消费端时，只报告本地协议测试结果。
- 同步 DTO 必须经过 `MobileSnapshotRedactor` 边界（R4）。
