import Foundation
import Testing
import UserNotifications
@testable import UsageDock

@Suite("AI Feed")
struct AIFeedTests {
    @Test("Notifications stay off until the user explicitly enables reminders")
    func notificationPermissionIsUserInitiated() {
        #expect(AIFeedStore.resolvedNotificationsEnabled(storedValue: nil) == false)
        #expect(AIFeedStore.resolvedNotificationsEnabled(storedValue: NSNumber(value: false)) == false)
        #expect(AIFeedStore.resolvedNotificationsEnabled(storedValue: NSNumber(value: true)) == true)
        #expect(AIFeedStore.shouldRequestNotificationPermission(
            notificationsEnabled: false,
            authorizationStatus: .notDetermined
        ) == false)
        #expect(AIFeedStore.shouldRequestNotificationPermission(
            notificationsEnabled: true,
            authorizationStatus: .notDetermined
        ) == true)
        #expect(AIFeedStore.shouldRequestNotificationPermission(
            notificationsEnabled: true,
            authorizationStatus: .denied
        ) == false)
    }

    @Test("Token reset language receives the highest priority")
    func tokenResetPriority() {
        #expect(FeedPriorityClassifier.classify("We increased the API token rate limit and the quota resets every five hours.") == .tokenReset)
        #expect(FeedPriorityClassifier.classify("Claude 使用额度将在五小时后重置") == .tokenReset)
        #expect(
            FeedPriorityClassifier.classify(
                "Enjoy reset usage limits for all paid users for Codex and ChatGPT Work."
            ) == .tokenReset
        )
    }

    @Test("Major model launches are pinned without treating ordinary chatter as major")
    func majorUpdatePriority() {
        #expect(FeedPriorityClassifier.classify("Introducing our new model, available now in the API.") == .majorUpdate)
        #expect(FeedPriorityClassifier.classify("I enjoyed talking about model behavior today.") == .normal)
    }

    @Test("Rotating tier selects the five hottest accounts")
    func rotatingTierHeatSelection() {
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let posts = (0..<6).map { index in
            makePost(
                id: "\(index)",
                username: "candidate\(index)",
                createdAt: base.addingTimeInterval(Double(index)),
                likes: index * 10,
                reposts: index,
                replies: 0,
                tier: .rotating,
                text: "Codex model update \(index)"
            )
        }

        let selection = AIFeedCollectionPolicy.selectRotating(from: posts)

        #expect(selection.usernames.count == 5)
        #expect(selection.usernames.first == "candidate5")
        #expect(!selection.usernames.contains("candidate0"))
        #expect(Set(selection.posts.map { $0.username.lowercased() }) == Set(selection.usernames))
    }

    @Test("Information value outranks raw engagement")
    func recommendationUsesInformationValue() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let viralNoise = makePost(
            id: "viral-noise",
            username: "elonmusk",
            createdAt: now,
            likes: 1_000_000,
            reposts: 100_000,
            tier: .rotating,
            text: "Mass drivers on the Moon!"
        )
        let usefulUpdate = makePost(
            id: "useful-update",
            username: "simonw",
            createdAt: now.addingTimeInterval(-21_600),
            likes: 8,
            reposts: 2,
            tier: .rotating,
            text: "Codex API usage limit update is available now."
        )

        let selection = AIFeedCollectionPolicy.selectRotating(
            from: [viralNoise, usefulUpdate],
            maxAccounts: 1,
            now: now
        )

        #expect(selection.usernames == ["simonw"])
        #expect(selection.posts.map(\.id) == ["useful-update"])
    }

    @Test("Critical low-engagement posts bypass rotating account popularity")
    func criticalPostsBypassPopularity() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let popularPosts = (0..<5).map { index in
            makePost(
                id: "popular-\(index)",
                username: "popular\(index)",
                createdAt: now,
                likes: 10_000 + index,
                tier: .rotating,
                text: "New AI model benchmark update \(index)"
            )
        }
        let reset = makePost(
            id: "reset",
            username: "thsottiaux",
            createdAt: now.addingTimeInterval(-21_600),
            tier: .rotating,
            text: "Enjoy reset usage limits for all paid users for Codex.",
            priority: .tokenReset
        )

        let selection = AIFeedCollectionPolicy.selectRotating(
            from: popularPosts + [reset],
            maxAccounts: 5,
            now: now
        )

        #expect(selection.posts.first?.id == "reset")
        #expect(selection.usernames.contains("thsottiaux"))
    }

    @Test("Display curation filters noise and limits one-author flooding")
    func displayCurationAddsDiversity() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let muskPosts = (0..<5).map { index in
            makePost(
                id: "musk-\(index)",
                username: "elonmusk",
                createdAt: now.addingTimeInterval(Double(-index)),
                likes: 10_000 - index,
                tier: .rotating,
                text: "Grok coding model update \(index)"
            )
        }
        let noise = makePost(
            id: "noise",
            username: "elonmusk",
            createdAt: now,
            likes: 100_000,
            tier: .rotating,
            text: "Yes"
        )
        let other = makePost(
            id: "other",
            username: "simonw",
            createdAt: now,
            tier: .rotating,
            text: "Claude API context window update"
        )

        let curated = AIFeedCollectionPolicy.curateForDisplay(
            muskPosts + [noise, other],
            now: now
        )

        #expect(curated.filter { $0.username == "elonmusk" }.count == 3)
        #expect(!curated.contains { $0.id == "noise" })
        #expect(curated.contains { $0.id == "other" })
    }

    @Test("Trending combines momentum with critical-event importance")
    func trendingBalancesMomentumAndImportance() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let viral = makePost(
            id: "viral",
            username: "simonw",
            createdAt: now.addingTimeInterval(-1_800),
            likes: 50_000,
            reposts: 10_000,
            replies: 2_000,
            tier: .rotating,
            text: "New Claude coding model benchmark"
        )
        let reset = makePost(
            id: "reset",
            username: "thsottiaux",
            createdAt: now.addingTimeInterval(-21_600),
            likes: 12,
            reposts: 3,
            replies: 1,
            tier: .primary,
            text: "Enjoy reset usage limits for all paid users for Codex.",
            priority: .tokenReset
        )
        let noise = makePost(
            id: "noise",
            username: "elonmusk",
            createdAt: now,
            likes: 1_000_000,
            reposts: 100_000,
            tier: .rotating,
            text: "Yes"
        )

        let trending = AIFeedCollectionPolicy.sortForTrending(
            [viral, reset, noise],
            now: now
        )

        #expect(trending.map(\.id) == ["reset", "viral"])
    }

    @Test("Daily collection applies tier-specific retention caps")
    func dailyCollectionCapsEachTier() {
        let dayStart = Date(timeIntervalSince1970: 2_000_000_000)
        let primary = (0..<55).map { index in
            makePost(
                id: "p\(index)",
                username: "OpenAI",
                createdAt: dayStart.addingTimeInterval(Double(index)),
                likes: index,
                tier: .primary
            )
        }
        let rotating = (0..<55).map { index in
            makePost(
                id: "r\(index)",
                username: "Kimi_Moonshot",
                createdAt: dayStart.addingTimeInterval(Double(index)),
                likes: index,
                tier: .rotating
            )
        }
        let yesterday = makePost(
            id: "old",
            username: "OpenAI",
            createdAt: dayStart.addingTimeInterval(-1),
            tier: .primary
        )

        let merged = AIFeedCollectionPolicy.mergeDaily(
            existing: [yesterday],
            fetched: primary + rotating,
            dayStart: dayStart
        )

        #expect(merged.count == 75)
        #expect(merged.filter { $0.tier == .primary }.count == 50)
        #expect(merged.filter { $0.tier == .rotating }.count == 25)
        #expect(!merged.contains { $0.id == "old" })
    }

    @Test("Curated API payload preserves server priority and canonical URL")
    func curatedPayloadDecoding() throws {
        let data = Data(
            """
            {
              "items": [{
                "id": "curated-1",
                "text": "Usage limit changed.",
                "author": {"username": "OpenAI", "displayName": "OpenAI"},
                "publishedAt": "2026-07-18T10:00:00Z",
                "url": "https://example.com/curated-1",
                "priority": "token_reset",
                "tier": "rotating",
                "metrics": {"likes": 4, "reposts": 3, "replies": 2}
              }]
            }
            """.utf8
        )

        let posts = try CuratedFeedService.decode(data: data)
        #expect(posts.first?.priority == .tokenReset)
        #expect(posts.first?.postURL.absoluteString == "https://example.com/curated-1")
        #expect(posts.first?.tier == .rotating)
    }

    private func makePost(
        id: String,
        username: String,
        createdAt: Date,
        likes: Int = 0,
        reposts: Int = 0,
        replies: Int = 0,
        tier: AIFeedTier,
        text: String? = nil,
        priority: AIFeedPriority = .normal
    ) -> AIFeedPost {
        AIFeedPost(
            id: id,
            text: text ?? "Post \(id)",
            username: username,
            displayName: username,
            createdAt: createdAt,
            metrics: .init(likes: likes, reposts: reposts, replies: replies),
            priority: priority,
            externalURL: nil,
            tier: tier
        )
    }
}
