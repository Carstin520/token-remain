import Foundation
import Testing
@testable import UsageDock

@Suite("Model vendor marks")
struct ModelVendorTests {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    private func usage(_ model: String, tokens: Int64, cents: Double? = nil) -> ProviderModelUsage {
        ProviderModelUsage(
            model: model,
            inputTokens: tokens,
            outputTokens: 0,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
            costCents: cents
        )
    }

    @Test("Model identifiers resolve to their vendor")
    func resolvesVendors() {
        let cases: [(String, ModelVendor)] = [
            ("claude-4.5-sonnet-thinking", .anthropic),
            ("claude-4.1-opus", .anthropic),
            ("gpt-5-codex", .openai),
            ("gpt-oss-120b", .openai),
            ("o3", .openai),
            ("o4-mini", .openai),
            ("gemini-2.5-pro", .google),
            ("grok-code-fast-1", .xai),
            ("deepseek-v3.1", .deepseek),
            ("deepseek-r1-distill-qwen-32b", .deepseek),
            ("kimi-k2-instruct", .moonshot),
            ("glm-4.6", .zhipu),
            ("MiniMax-M2", .minimax),
            ("qwen3-coder", .alibaba),
            ("mimo-v2", .xiaomi),
            ("doubao-seed-code", .bytedance),
            ("mystery-model", .other),
            // "o" followed by letters is not an OpenAI reasoning model.
            ("ollama-local", .other)
        ]
        for (model, vendor) in cases {
            #expect(ModelVendor.resolve(model: model) == vendor, "\(model)")
        }
    }

    @Test("Vendors are grouped, ranked by usage and capped at three")
    func ranksTopThreeVendors() {
        let marks = ModelVendorMark.ranked([
            usage("gpt-5", tokens: 400),
            usage("claude-4.5-sonnet", tokens: 300),
            usage("claude-4.1-opus", tokens: 250),
            usage("gemini-2.5-pro", tokens: 500),
            usage("grok-code-fast-1", tokens: 100),
            usage("idle-model", tokens: 0)
        ])

        #expect(marks.map(\.vendor) == [.anthropic, .google, .openai])
        #expect(marks[0].totalTokens == 550)
        #expect(marks[0].models.map(\.name) == ["claude-4.5-sonnet", "claude-4.1-opus"])
    }

    @Test("Cost breaks a token tie between vendors")
    func costBreaksTies() {
        let marks = ModelVendorMark.ranked([
            usage("gpt-5", tokens: 100, cents: 50),
            usage("claude-4.5-sonnet", tokens: 100, cents: 120)
        ])
        #expect(marks.map(\.vendor) == [.anthropic, .openai])
    }

    @Test("Tooltip names the vendor and each model with its usage")
    func helpText() {
        let mark = ModelVendorMark.ranked([usage("claude-4.5-sonnet", tokens: 1_200, cents: 250)])[0]
        let lines = mark.helpText.components(separatedBy: "\n")
        #expect(lines.first == "Anthropic")
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("claude-4.5-sonnet · "))
    }

    @Test("Cursor's Other Models pool reads Others followed by third-party vendors")
    func cursorOtherModelsSummary() throws {
        var quota = try CursorAPIUsageParser.parse(Data("""
        {"enabled": true, "planUsage": {"autoPercentUsed": 67.9, "apiPercentUsed": 100}}
        """.utf8), now: now)
        quota.modelUsage = [
            usage("auto", tokens: 9_000),
            usage("composer-1", tokens: 8_000),
            usage("gpt-5", tokens: 200),
            usage("claude-4.5-sonnet", tokens: 700)
        ]

        let summary = try #require(quota.modelVendorSummary(for: quota.primary))
        #expect(summary.label == ProviderQuota.otherModelsLabel)
        #expect(summary.marks.map(\.vendor) == [.anthropic, .openai])
        let auto = try #require(quota.uniqueScopedWindows.first)
        #expect(quota.modelVendorSummary(for: auto.window, scopedName: auto.displayName) == nil)
    }

    @Test("Without third-party usage the pool keeps its text name")
    func cursorWithoutUsageKeepsName() throws {
        var quota = try CursorAPIUsageParser.parse(Data("""
        {"enabled": true, "planUsage": {"autoPercentUsed": 10, "apiPercentUsed": 0}}
        """.utf8), now: now)
        let api = try #require(quota.uniqueScopedWindows.first)
        #expect(quota.modelVendorSummary(for: api.window, scopedName: api.displayName) == nil)

        quota.modelUsage = [usage("auto", tokens: 9_000)]
        #expect(quota.modelVendorSummary(for: api.window, scopedName: api.displayName) == nil)
    }

    @Test("Cursor's own models are recognized by name")
    func cursorModelNames() {
        for model in ["auto", "default", "composer-1", "cursor-small", " Auto "] {
            #expect(CursorAPIUsageParser.isCursorModel(model), "\(model)")
        }
        for model in ["gpt-5", "claude-4.5-sonnet", "autonomous-x"] {
            #expect(!CursorAPIUsageParser.isCursorModel(model), "\(model)")
        }
    }

    @Test("Antigravity's Claude / GPT pool reads Others with both vendors in a fixed order")
    func antigravityThirdPartySummary() {
        let quota = ProviderQuota(
            provider: .antigravity,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, poolName: "Gemini"),
            secondary: nil,
            planName: nil,
            capturedAt: now
        )
        let thirdParty = QuotaWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil)
        let summary = quota.modelVendorSummary(for: thirdParty, scopedName: AntigravityUsageParser.thirdPartyPoolName)
        #expect(summary?.label == ProviderQuota.otherModelsLabel)
        #expect(summary?.marks.map(\.vendor) == [.anthropic, .openai])
        #expect(quota.modelVendorSummary(for: quota.primary) == nil)
    }

    @Test("Relays put their logos after the primary row's own name only")
    func relaySummaryOnPrimaryRow() {
        let credits = QuotaWindow(usedPercent: 30, windowMinutes: 0, resetsAt: nil)
        var quota = ProviderQuota(
            provider: .openrouter,
            primary: QuotaWindow(usedPercent: 50, windowMinutes: 43_200, resetsAt: nil),
            secondary: credits,
            planName: nil,
            capturedAt: now,
            scopedWindows: [
                ScopedQuotaWindow(scopeID: "openrouter_credits", displayName: "Credits", window: credits, observedAt: now)
            ]
        )
        #expect(quota.modelVendorSummary(for: quota.primary) == nil)

        quota.modelUsage = [usage("anthropic/claude-sonnet-4.5", tokens: 900), usage("openai/gpt-5", tokens: 300)]
        let summary = quota.modelVendorSummary(for: quota.primary)
        #expect(summary?.label == nil)
        #expect(summary?.marks.map(\.vendor) == [.anthropic, .openai])
        #expect(quota.modelVendorSummary(for: credits) == nil)
        #expect(quota.modelVendorSummary(for: credits, scopedName: "Credits") == nil)

        // A relay balance re-hosted under Claude Code keeps its logos.
        let hosted = quota.attributed(
            to: .claude,
            source: QuotaAttribution(provider: .openrouter, displayName: "OpenRouter", routeIdentifier: "openrouter")
        )
        #expect(hosted.modelVendorSummary(for: hosted.primary)?.marks.count == 2)
    }

    @Test("An account-labeled popover row drops the Others label but keeps relay logos")
    func popoverAccountRows() throws {
        var cursor = try CursorAPIUsageParser.parse(Data("""
        {"enabled": true, "planUsage": {"autoPercentUsed": 10, "apiPercentUsed": 90}}
        """.utf8), now: now)
        cursor.modelUsage = [usage("gpt-5", tokens: 200)]
        #expect(PopoverQuotaWidget.vendorSummary(in: cursor, window: cursor.primary, accountName: nil) != nil)
        #expect(PopoverQuotaWidget.vendorSummary(in: cursor, window: cursor.primary, accountName: "Work") == nil)

        var relay = ProviderQuota(
            provider: .thirdParty,
            primary: QuotaWindow(usedPercent: 20, windowMinutes: 0, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: now
        )
        relay.modelUsage = [usage("deepseek-v3.1", tokens: 50)]
        #expect(PopoverQuotaWidget.vendorSummary(in: relay, window: relay.primary, accountName: "Work") != nil)
    }

    @Test("The title puts the name before the logos and the window after them")
    func vendorTitleParts() {
        let named = QuotaWindowRow.vendorTitleParts(windowMinutes: 300, name: "Others", attribution: nil)
        #expect(named.leading == "Others")
        #expect(named.trailing?.hasPrefix("· ") == true)

        let unnamed = QuotaWindowRow.vendorTitleParts(windowMinutes: 0, name: nil, attribution: nil)
        #expect(unnamed.trailing == nil)
        #expect(!unnamed.leading.isEmpty)

        let hosted = QuotaWindowRow.vendorTitleParts(
            windowMinutes: 0,
            name: nil,
            attribution: QuotaAttribution(provider: .openrouter, displayName: "OpenRouter", routeIdentifier: "openrouter")
        )
        #expect(hosted.leading.hasPrefix("OpenRouter · "))
    }

    @Test("The bundled OpenAI mark resolves for tests and debug builds")
    func openAIAssetResolves() {
        #expect(ModelVendorIcon.openAIResourceURL() != nil)
    }
}
