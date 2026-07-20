import Foundation
import Testing
@testable import UsageDock

@Suite("AI Feed")
struct AIFeedTests {
    @Test("Primary tier is fixed and Elon Musk rotates")
    func primaryTierAccounts() {
        #expect(
            AIFeedAccount.primary.map(\.username) == [
                "btibor91",
                "sama",
                "claudeai",
                "AnthropicAI",
                "OpenAI",
                "thsottiaux",
                "karpathy"
            ]
        )
        #expect(AIFeedAccount.rotatingCandidates.first?.username == "elonmusk")
        #expect(AIFeedAccount.tier(for: "elonmusk") == .rotating)
        #expect(AIFeedAccount.primary.allSatisfy { AIFeedAccount.tier(for: $0.username) == .primary })
        #expect(
            AIFeedAccount.rotatingCandidates.allSatisfy {
                AIFeedAccount.tier(for: $0.username) == .rotating
            }
        )
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

    @Test("X search payload maps authors, metrics, priority, and ordering")
    func searchPayloadDecoding() throws {
        let data = Data(
            """
            {
              "data": [
                {
                  "id": "2",
                  "text": "A regular research note.",
                  "author_id": "20",
                  "created_at": "2026-07-18T10:00:00.000Z",
                  "public_metrics": {"like_count": 3, "retweet_count": 2, "reply_count": 1, "quote_count": 0, "bookmark_count": 0, "impression_count": 10}
                },
                {
                  "id": "1",
                  "text": "Introducing a new model, now available in the API.",
                  "author_id": "10",
                  "created_at": "2026-07-18T09:00:00.000Z",
                  "public_metrics": {"like_count": 30, "retweet_count": 20, "reply_count": 10, "quote_count": 0, "bookmark_count": 0, "impression_count": 100}
                }
              ],
              "includes": {
                "users": [
                  {"id": "10", "name": "OpenAI", "username": "OpenAI"},
                  {"id": "20", "name": "Tibor Blaho", "username": "btibor91"}
                ]
              }
            }
            """.utf8
        )

        let posts = try XFeedService.decode(data: data, tier: .rotating)

        #expect(posts.count == 2)
        #expect(posts.first?.id == "1")
        #expect(posts.first?.priority == .majorUpdate)
        #expect(posts.first?.displayName == "OpenAI")
        #expect(posts.first?.metrics.likes == 30)
        #expect(posts.last?.username == "btibor91")
        #expect(posts.allSatisfy { $0.tier == .rotating })
    }

    @Test("Recent search is bounded to the Shanghai day and 50 results")
    func dailySearchURL() throws {
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-18T08:00:00Z")
        )
        let start = AIFeedCollectionPolicy.startOfDay(for: now)
        let url = try XFeedService.searchURL(
            accounts: AIFeedAccount.primary,
            startTime: start,
            maxResults: 50
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        #expect(values["max_results"] == "50")
        #expect(values["start_time"] == "2026-07-17T16:00:00Z")
        #expect(values["query"]?.contains("from:karpathy") == true)
        #expect(values["query"]?.contains("from:thsottiaux") == true)
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

    @Test("Local engineering plist imports the X token without embedding it in code")
    func localConfigurationImport() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>XBearerToken</key><string>test-token</string>
            </dict></plist>
            """.utf8
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageDockFeed-\(UUID().uuidString).plist")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try LocalFeedConfigurationImporter().token(from: url) == "test-token")
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
