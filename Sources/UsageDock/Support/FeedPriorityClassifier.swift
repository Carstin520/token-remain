import Foundation

enum FeedPriorityClassifier {
    static func classify(_ text: String) -> AIFeedPriority {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if isTokenReset(normalized) {
            return .tokenReset
        }
        if isMajorUpdate(normalized) {
            return .majorUpdate
        }
        return .normal
    }

    private static func isTokenReset(_ text: String) -> Bool {
        let usageTerms = [
            "token", "context window", "usage limit", "rate limit", "quota",
            "message limit", "compute limit", "weekly limit", "hourly limit",
            "paid user", "all plans", "reset bank", "banked reset",
            "额度", "配额", "速率限制", "上下文窗口"
        ]
        let changeTerms = [
            "reset", "refill", "refresh", "renew", "rolling window",
            "increase", "decrease", "restore", "back to 100%", "on the house",
            "double", "2x", "unlimited",
            "重置", "恢复", "刷新", "提升", "下调", "翻倍"
        ]
        return text.containsAny(usageTerms) && text.containsAny(changeTerms)
    }

    private static func isMajorUpdate(_ text: String) -> Bool {
        let releaseTerms = [
            "introducing", "we're launching", "we are launching", "released",
            "now available", "rolling out", "we shipped", "announcing",
            "general availability", "breaking change", "deprecat", "sunset",
            "new model", "pricing update", "price change", "outage", "incident",
            "degraded", "back online", "resolved", "service restored",
            "推出", "发布", "上线", "正式可用", "重大更新", "弃用", "停止支持",
            "价格调整", "故障", "中断", "服务恢复"
        ]
        let productTerms = [
            "model", "api", "claude", "gpt", "chatgpt", "openai", "anthropic",
            "codex", "grok", "xai", "agent", "context", "token",
            "模型", "接口", "智能体", "上下文", "额度"
        ]
        return text.containsAny(releaseTerms) && text.containsAny(productTerms)
    }
}

private extension String {
    func containsAny(_ candidates: [String]) -> Bool {
        candidates.contains(where: contains)
    }
}
