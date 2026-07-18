import Foundation

enum AIFeedCollectionPolicy {
    static let maxPostsPerTier = 50
    static let fetchResultsPerTier = 100
    static let rotatingAccountLimit = 5
    static let minimumRotatingRelevanceScore = 40

    static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    static func startOfDay(
        for date: Date,
        calendar: Calendar = shanghaiCalendar
    ) -> Date {
        calendar.startOfDay(for: date)
    }

    static func dayKey(
        for date: Date,
        calendar: Calendar = shanghaiCalendar
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    struct RotationSelection: Equatable {
        let usernames: [String]
        let posts: [AIFeedPost]
    }

    static func selectRotating(
        from posts: [AIFeedPost],
        maxAccounts: Int = rotatingAccountLimit,
        maxPosts: Int = maxPostsPerTier,
        now: Date = Date()
    ) -> RotationSelection {
        let rotatingPosts = posts.filter { $0.tier == .rotating }
        let importantPosts = sortForRecommendation(
            rotatingPosts.filter { $0.priority != .normal },
            now: now
        )
        let eligibleNormalPosts = rotatingPosts.filter {
            $0.priority == .normal
                && topicRelevanceScore(for: $0.text) >= minimumRotatingRelevanceScore
        }
        let grouped = Dictionary(grouping: eligibleNormalPosts) {
            $0.username.lowercased()
        }
        let rankedUsernames = grouped
            .map { username, accountPosts in
                (
                    username: username,
                    score: sortForRecommendation(accountPosts, now: now)
                        .prefix(3)
                        .reduce(0) { $0 + recommendationScore(for: $1, now: now) },
                    latest: accountPosts.map(\.createdAt).max() ?? .distantPast
                )
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.latest != $1.latest { return $0.latest > $1.latest }
                return $0.username < $1.username
            }
            .map(\.username)

        var selectedUsernames: [String] = []
        for post in importantPosts {
            let username = post.username.lowercased()
            if !selectedUsernames.contains(username) {
                selectedUsernames.append(username)
            }
        }
        for username in rankedUsernames
            where selectedUsernames.count < maxAccounts && !selectedUsernames.contains(username) {
            selectedUsernames.append(username)
        }

        let selected = Set(selectedUsernames)
        let selectedPosts = sortForRecommendation(
            importantPosts + eligibleNormalPosts.filter {
                selected.contains($0.username.lowercased())
            },
            now: now
        )
        return RotationSelection(
            usernames: selectedUsernames,
            posts: Array(selectedPosts.prefix(maxPosts))
        )
    }

    static func sortForRecommendation(
        _ posts: [AIFeedPost],
        now: Date = Date()
    ) -> [AIFeedPost] {
        posts.sorted {
            let lhsScore = recommendationScore(for: $0, now: now)
            let rhsScore = recommendationScore(for: $1, now: now)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    static func recommendationScore(for post: AIFeedPost, now: Date = Date()) -> Int {
        let priorityScore: Int
        switch post.priority {
        case .tokenReset: priorityScore = 100_000
        case .majorUpdate: priorityScore = 50_000
        case .normal: priorityScore = 0
        }

        let relevanceScore = topicRelevanceScore(for: post.text) * 5
        let engagement = max(0, engagementScore(for: post))
        let engagementScore = min(120, Int(Double(engagement).squareRoot()) * 4)
        let ageHours = max(0, now.timeIntervalSince(post.createdAt) / 3_600)
        let freshnessScore = max(0, 72 - Int(ageHours * 3))
        let sourceScore = post.tier == .primary ? 30 : 0
        return priorityScore + relevanceScore + engagementScore + freshnessScore + sourceScore
    }

    static func topicRelevanceScore(for text: String) -> Int {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let directImpactTerms = [
            "usage limit", "rate limit", "quota", "token", "context window",
            "pricing", "price", "credit", "paid user", "all plans",
            "outage", "incident", "degraded", "back online", "resolved",
            "额度", "配额", "限额", "价格", "故障", "中断", "恢复"
        ]
        let aiProductTerms = [
            "codex", "chatgpt", "openai", "claude", "anthropic", "gpt",
            "grok", "xai", "kimi", "deepseek", "mistral", "gemini",
            "model", "api", "agent", "模型", "接口", "智能体"
        ]
        let actionableTerms = [
            "launch", "release", "available", "rolling out", "introducing",
            "reset", "increase", "decrease", "fixed", "update", "benchmark",
            "发布", "上线", "推出", "重置", "提升", "下调", "修复", "更新"
        ]
        let noiseTerms = [
            "election", "politics", "government", "tesla", "spacex",
            "mars", "moon", "dogecoin", "crypto", "移民", "选举", "火星", "月球"
        ]

        var score = 0
        if normalized.containsAny(directImpactTerms) { score += 90 }
        if normalized.containsAny(aiProductTerms) { score += 70 }
        if normalized.containsAny(actionableTerms) { score += 35 }
        if normalized.containsAny(noiseTerms) { score -= 180 }
        return score
    }

    static func mergeDaily(
        existing: [AIFeedPost],
        fetched: [AIFeedPost],
        dayStart: Date,
        maxPostsPerTier: Int = maxPostsPerTier
    ) -> [AIFeedPost] {
        var byID: [String: AIFeedPost] = [:]
        for post in existing where post.createdAt >= dayStart {
            byID[post.id] = post
        }
        for post in fetched where post.createdAt >= dayStart {
            byID[post.id] = post
        }

        return AIFeedTier.allCases.flatMap { tier in
            AIFeedPost.sortedForDisplay(
                byID.values.filter { $0.tier == tier }
            )
            .prefix(maxPostsPerTier)
        }
    }

    static func engagementScore(for post: AIFeedPost) -> Int {
        post.metrics.likes + 2 * post.metrics.reposts + post.metrics.replies
    }
}

private extension String {
    func containsAny(_ candidates: [String]) -> Bool {
        candidates.contains(where: contains)
    }
}
