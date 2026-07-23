# UsageDock Curated Feed Contract

X API 凭证和内容筛选全部留在 TokenRemain Broadcast Worker。Apple 客户端只读取公开结果，不直接调用 X API，也没有用户填写 X Token 的入口。

服务端收集规则：

- 第一梯队：`btibor91`、`sama`、`claudeai`、`AnthropicAI`、`OpenAI`、`karpathy`，每 10 分钟检查一次，UTC 自然日合计最多发布 30 条。
- 第二梯队：每小时搜索第一梯队之外的 AI 相关账号，结合帖子互动、账号影响力、账号活跃度和时效排序，UTC 自然日始终保留分数最高的 20 条；后出现的强热点可以替换较弱条目，同一动态账号每天最多占 3 条。
- 两层都只接受独立原帖；查询端和入库端都会拒绝回复、转帖和引用帖。

客户端默认使用不含凭证的生产广播根地址
`https://tokenremain-broadcast.jamescarstin520.workers.dev`，并支持以下覆盖入口：

- macOS：构建环境变量 `TOKENREMAIN_BROADCAST_BASE_URL`
- iOS / iPadOS：同名 Xcode build setting
- 运行时读取的 Info.plist 键：`TokenRemainBroadcastBaseURL`

## 官网 DMG 下载统计

- `GET /v1/downloads/macos`：只把 `macos_dmg` 的匿名聚合计数加一，然后
  `302` 跳转到 GitHub Release 的 `TokenRemain.dmg`。
- `GET /v1/downloads/stats`：向官网公开累计下载次数。
- D1 只保存一个累计整数和最后更新时间；不保存 IP、User-Agent、设备标识、
  Cookie 或逐次下载事件。

## GET /v1/ai-feed

响应：

```json
{
  "items": [
    {
      "id": "curated-20260718-001",
      "text": "Claude usage limits now reset every five hours.",
      "author": {
        "username": "claudeai",
        "displayName": "Claude"
      },
      "publishedAt": "2026-07-18T08:30:00Z",
      "url": "https://x.com/claudeai/status/123",
      "priority": "token_reset",
      "tier": "primary",
      "metrics": {
        "likes": 1200,
        "reposts": 180,
        "replies": 90
      }
    }
  ]
}
```

`priority` 的允许值：

- `token_reset`：Token、额度、速率限制或重置变化；客户端置顶并通知。
- `major_update`：重大模型、API、价格或产品变化；客户端置顶并通知。
- `normal`：普通行业动态。

`tier` 的允许值：

- `primary`：固定第一梯队，服务端每日最多发布 30 条。
- `rotating`：按当日互动热度入选的第二梯队，服务端每日最多发布 20 条。

服务端未提供 `tier` 时，客户端按 `primary` 处理；客户端没有监控账号列表。

服务端输出即为最终审核结果。客户端不会把被服务端过滤掉的原始帖子重新加入 Feed。

## Apple 全生态推送

正式推送时由服务端基于同一个已审核 item 生成 APNs payload。所有客户端使用 item `id` 去重，并用 `priority` 决定展示级别。推荐 payload：

```json
{
  "aps": {
    "alert": {
      "title": "UsageDock · Token / 额度更新",
      "subtitle": "Claude · @claudeai",
      "body": "Claude usage limits now reset every five hours."
    },
    "sound": "default",
    "thread-id": "ai-feed"
  },
  "feedItemID": "curated-20260718-001",
  "url": "https://x.com/claudeai/status/123",
  "priority": "token_reset"
}
```

当前实现由服务端每小时检查设备所在时区，并在本地时间 09:00 所在小时为每个已允许通知的安装发送一次去重摘要；即使过去 24 小时没有新帖，只要 Feed 已有内容，用户仍会收到查看最新动态的每日入口。高优先级手工发布可即时推送。

设备注册不需要用户账户：

```json
{
  "installationId": "mac_or_ios_generated_id",
  "registrationKey": "device_generated_revocation_secret",
  "deviceToken": "apns_device_token_hex",
  "platform": "macos",
  "locale": "zh-Hans",
  "timezone": "Asia/Shanghai",
  "notificationsEnabled": true
}
```

服务端只保存注册和投递所需字段。用户关闭通知时，客户端用设备本地的 `registrationKey` 调用 `DELETE /v1/devices/{installationId}` 使注册失效。
