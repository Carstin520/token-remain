# UsageDock Curated Feed Contract

产品化后，X API 凭证和内容筛选全部留在 UsageDock 服务端。Apple 客户端只读取已审核的结果，不直接调用 X API。

工程切换入口：

`Sources/UsageDock/Configuration/FeedConfiguration.swift`

将 `FeedConfiguration.delivery` 从 `.directXAPI` 改为：

```swift
.curatedAPI(
    endpoint: URL(string: "https://api.usagedock.app/v1/ai-feed")!
)
```

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

- `primary`：固定第一梯队，客户端每日最多保留 50 条。
- `rotating`：按当日互动热度入选的第二梯队，客户端每日最多保留 25 条。

服务端未提供 `tier` 时，客户端会按本地账号配置推断层级。

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

当前 macOS 版本仍通过轮询精选接口后发送本地通知；接入 APNs 后，服务端可以在审核完成时直接推送到 macOS、iPhone、iPad 和 Apple Watch。
