import Foundation
import Security
import Testing
@testable import UsageDock

@Suite("Claude oauth/usage parser")
struct ClaudeOAuthUsageParserTests {
    @Test("Parses five hour and seven day windows with ISO reset times")
    func parsesBothWindows() throws {
        let payload = """
        {
          "five_hour": {"utilization": 12.5, "resets_at": "2026-07-21T12:00:00Z"},
          "seven_day": {"utilization": 40, "resets_at": "2026-07-24T13:00:00.000Z"}
        }
        """
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let quota = try ClaudeOAuthUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            now: now
        )

        #expect(quota.provider == .claude)
        #expect(quota.primary.usedPercent == 12.5)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt == ISO8601DateFormatter().date(from: "2026-07-21T12:00:00Z"))
        #expect(quota.secondary?.usedPercent == 40)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.planName == "Max 20x")
        #expect(quota.capturedAt == now)
    }

    @Test("Parses model-scoped weekly windows such as Fable")
    func parsesFableWindow() throws {
        let payload = """
        {
          "five_hour": {"utilization": 12.5},
          "seven_day": {"utilization": 40},
          "seven_day_fable": {"utilization": 67, "resets_at": "2026-07-24T13:00:00Z"}
        }
        """

        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        let fable = try #require(quota.scopedWindows?.first)
        #expect(fable.scopeID == "fable")
        #expect(fable.displayName == "Fable")
        #expect(fable.window.usedPercent == 67)
        #expect(fable.window.windowMinutes == 10_080)
    }

    @Test("Parses Fable from the structured limits schema when the legacy key is absent")
    func parsesStructuredLimitsFableWindow() throws {
        let payload = """
        {
          "limits": [
            {"kind":"session","group":"session","percent":7,"resets_at":"2026-08-13T04:00:00Z"},
            {"kind":"weekly_all","group":"weekly","percent":57,"resets_at":"2026-08-14T05:00:00Z"},
            {"kind":"weekly_notice","group":"weekly","percent":100,"label":"Learn more about usage limits"},
            {
              "kind":"weekly_scoped",
              "group":"weekly",
              "percent":98,
              "resets_at":"2026-08-14T05:00:00Z",
              "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}
            }
          ]
        }
        """

        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        let fable = try #require(quota.fableWindow)

        #expect(quota.primary.usedPercent == 7)
        #expect(quota.secondary?.usedPercent == 57)
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable"])
        #expect(fable.window.usedPercent == 98)
        #expect(fable.window.resetsAt == quota.secondary?.resetsAt)
    }

    @Test("CLI scoped quota supplements API values without replacing them")
    func mergesCLIScopedQuotaIntoAPIQuota() throws {
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8),
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x"
        )
        let fable = ScopedQuotaWindow(
            scopeID: "fable",
            displayName: "Fable",
            window: QuotaWindow(usedPercent: 67, windowMinutes: 10_080, resetsAt: nil)
        )

        let merged = api.mergingScopedWindows([fable])

        #expect(merged.primary.usedPercent == 12)
        #expect(merged.secondary?.usedPercent == 34)
        #expect(merged.planName == "Max 20x")
        #expect(merged.fableWindow?.window.usedPercent == 67)
    }

    @Test("A general refresh retains the active Fable quota")
    func retainsActiveFableAcrossGeneralRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-300),
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 67,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(3_600)
                    ),
                    observedAt: now.addingTimeInterval(-300)
                )
            ]
        )

        let retained = api.retainingActiveScopedWindows(from: previous, now: now)

        #expect(retained.fableWindow?.window.usedPercent == 67)
    }

    @Test("A reset further out than its own window cannot keep a window alive")
    func dropsScopedWindowWithImplausibleReset() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-300),
            // 一次残缺的 /usage 重绘会把 Fable 的重置解析成一年之后。旧的
            // `resetsAt > now` 判据对这种值永远成立,坏卡片能活满整个周期。
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 98,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(364 * 86_400)
                    ),
                    observedAt: now.addingTimeInterval(-300)
                )
            ]
        )

        #expect(api.retainingActiveScopedWindows(from: previous, now: now).fableWindow == nil)
    }

    @Test("A scoped window from an older build is dropped rather than kept forever")
    func dropsScopedWindowWithoutObservationTimestamp() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-300),
            // 旧版本写下的快照没有 observedAt。此前它靠 previous.capturedAt 判新鲜,
            // 而那个时间戳每轮刷新都会被重写,于是这种窗口永远不过期。
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 67,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(3_600)
                    )
                )
            ]
        )

        #expect(api.retainingActiveScopedWindows(from: previous, now: now).fableWindow == nil)
    }

    @Test("A snapshot that reports its own scoped windows never resurrects older ones")
    func doesNotResurrectWhenCurrentSnapshotHasScopedWindows() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"""
            {"five_hour":{"utilization":12},"seven_day":{"utilization":34},
             "seven_day_fable":{"utilization":98}}
            """#.utf8),
            now: now
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-60),
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable_stale_copy",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 0,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(8 * 3_600)
                    ),
                    observedAt: now.addingTimeInterval(-60)
                )
            ]
        )

        let retained = api.retainingActiveScopedWindows(from: previous, now: now)

        // 本轮已经报了自己的 scoped 集合,缺席的就是真的没了,不该被复活成
        // 第二张"100% remaining"的 Fable 卡片。
        #expect(retained.uniqueScopedWindows.map(\.scopeID) == ["fable"])
        #expect(retained.fableWindow?.window.usedPercent == 98)
    }

    @Test("A screen fragment mistaken for a model name is rejected")
    func rejectsCorruptScopedWindowFromOlderParser() {
        // 真实缓存里捞到的化石:旧解析器把进度条和重置行吞进了 displayName,
        // usedPercent 为 0,于是弹窗在真实 Fable(98% used)旁边多画了一张
        // "100% remaining" 的卡片。修好解析器救不了已经存了这条记录的用户。
        let fossil = ScopedQuotaWindow(
            scopeID: "fable_40_used_resets_aug14_at_12",
            displayName: "Fable\n████████████████████    40%used\nResets Aug14 at 12:59pm(Asia/Shanghai",
            window: QuotaWindow(usedPercent: 0, windowMinutes: 10_080, resetsAt: nil)
        )
        let healthy = ScopedQuotaWindow(
            scopeID: "fable",
            displayName: "Fable",
            window: QuotaWindow(usedPercent: 98, windowMinutes: 10_080, resetsAt: nil)
        )

        #expect(!fossil.isPlausibleModelScope)
        #expect(healthy.isPlausibleModelScope)

        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 11, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: [healthy, fossil]
        )

        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable"])
    }

    @Test("An expired Fable quota is not retained")
    func dropsExpiredFableAcrossGeneralRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-300),
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 67,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(-1)
                    )
                )
            ]
        )

        let retained = api.retainingActiveScopedWindows(from: previous, now: now)

        #expect(retained.fableWindow == nil)
    }

    @Test("A stale Fable snapshot is dropped even when its reset remains in the future")
    func dropsStaleFableWithFutureReset() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8),
            now: now
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-901),
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 0,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(8 * 3_600 + 31 * 60)
                    ),
                    observedAt: now.addingTimeInterval(-901)
                )
            ]
        )

        let retained = api.retainingActiveScopedWindows(from: previous, now: now)

        #expect(retained.fableWindow == nil)
    }

    @Test("Freshly reset window keeps nil reset date instead of inventing one")
    func missingResetStaysNil() throws {
        let payload = """
        {"five_hour": {"utilization": 0, "resets_at": null}}
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 0)
        #expect(quota.primary.resetsAt == nil)
        #expect(quota.secondary == nil)
    }

    @Test("Epoch reset timestamps are accepted in seconds and milliseconds")
    func epochResets() throws {
        let payload = """
        {
          "five_hour": {"utilization": 5, "resets_at": 1784005200},
          "seven_day": {"utilization": 9, "resets_at": 1784005200000}
        }
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        let expected = Date(timeIntervalSince1970: 1_784_005_200)
        #expect(quota.primary.resetsAt == expected)
        #expect(quota.secondary?.resetsAt == expected)
    }

    @Test("A payload with no general window is rejected for PTY fallback")
    func missingGeneralWindowsThrow() {
        // 推理专用 token 的响应里两个账户级窗口都没有:仍然交给 PTY,
        // 不凭空造出订阅额度。只有模型级窗口也不算账户额度。
        for payload in [
            #"{}"#,
            #"{"five_hour": null, "seven_day": null, "extra_usage": {"is_enabled": false}}"#,
            #"{"five_hour": {"utilization": null}, "seven_day": {"utilization": null}}"#,
            #"{"seven_day_opus": {"utilization": 12}}"#,
            #"{"limits": []}"#
        ] {
            #expect(throws: ClaudeOAuthUsageService.APIError.self) {
                try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
            }
        }
    }

    /// 2026-11 起部分套餐不再有 5 小时会话窗(公开报道为已验证的 Ultra)。
    /// Claude Code 2.1.330 校验的响应结构里每个窗口都可空,/usage 画面对
    /// 空窗口整行省略。此前解析器把这种响应整体判为"无法识别"。
    @Test("An account without a session cap reports its weekly window as the only general quota")
    func weeklyOnlyLegacyPayload() throws {
        for payload in [
            #"{"five_hour": null, "seven_day": {"utilization": 40, "resets_at": "2026-11-27T05:00:00Z"}}"#,
            #"{"seven_day": {"utilization": 40, "resets_at": "2026-11-27T05:00:00Z"}}"#,
            // `five_hour` 对象还在、数值为 null:同样是"没有这个窗口"。
            #"{"five_hour": {"utilization": null, "resets_at": null}, "seven_day": {"utilization": 40, "resets_at": "2026-11-27T05:00:00Z"}}"#
        ] {
            let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

            #expect(quota.primary.windowMinutes == 10_080)
            #expect(quota.primary.usedPercent == 40)
            #expect(quota.primary.resetsAt == ISO8601DateFormatter().date(from: "2026-11-27T05:00:00Z"))
            // 周窗不能同时出现在两个槽位,也不能补一条 0% 的假会话窗。
            #expect(quota.secondary == nil)
            #expect(quota.generalQuotaSummary.window.windowMinutes == 10_080)
        }
    }

    @Test("Structured limits without a session row keep the weekly and model-scoped rows")
    func weeklyOnlyStructuredLimits() throws {
        // 字段与 Claude Code 2.1.330 的 limits[] 结构一致,含本解析器不使用的
        // severity / is_active / scope.surface。
        let payload = """
        {
          "five_hour": null,
          "seven_day": null,
          "limits": [
            {"kind":"weekly_all","group":"weekly","percent":31,"resets_at":"2026-11-27T05:00:00Z",
             "severity":"normal","is_active":true,"scope":null},
            {"kind":"weekly_scoped","group":"weekly","percent":64,"resets_at":"2026-11-27T05:00:00Z",
             "severity":"warning","is_active":false,
             "scope":{"model":{"display_name":"Fable"},"surface":null}},
            {"kind":"weekly_scoped","group":"weekly","percent":9,"resets_at":"2026-11-27T05:00:00Z",
             "severity":"normal","is_active":false,
             "scope":{"model":null,"surface":{"display_name":"Claude Code"}}}
          ]
        }
        """

        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        #expect(quota.primary.windowMinutes == 10_080)
        #expect(quota.primary.usedPercent == 31)
        #expect(quota.secondary == nil)
        // 分项行按服务端给的名字原样展示,模型和使用入口同样对待。
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable", "claude_code"])
        #expect(quota.uniqueScopedWindows.map(\.displayName) == ["Fable", "Claude Code"])
        #expect(quota.fableWindow?.window.usedPercent == 64)
    }

    // MARK: 自适应:服务端再调整额度行时不需要发版

    @Test("A window length this build has never seen is read from its key")
    func unknownLegacyDurationIsAGeneralWindow() throws {
        let payload = #"{"one_day": {"utilization": 20, "resets_at": "2026-11-24T05:00:00Z"}, "seven_day": {"utilization": 40}, "thirty_day_opus": {"utilization": 5}}"#
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        #expect(quota.primary.windowMinutes == 1_440)
        #expect(quota.primary.usedPercent == 20)
        #expect(quota.secondary?.windowMinutes == 10_080)
        // 非周窗的分项带时长后缀,不会和同名的周分项撞 ID。
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["opus_30d"])
        #expect(quota.uniqueScopedWindows.first?.window.windowMinutes == 43_200)
    }

    @Test("A third account-wide cap stays visible as a named row")
    func thirdGeneralWindowIsNotDropped() throws {
        let payload = """
        {
          "five_hour": {"utilization": 10},
          "seven_day": {"utilization": 40},
          "limits": [
            {"kind":"monthly_all","group":"monthly","percent":72,"resets_at":"2026-12-01T00:00:00Z",
             "severity":"warning","is_active":false,"scope":null}
          ]
        }
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.windowMinutes == 10_080)
        let overall = try #require(quota.uniqueScopedWindows.first)
        #expect(overall.scopeID == "overall_30d")
        #expect(overall.window.windowMinutes == 43_200)
        #expect(overall.window.usedPercent == 72)
        // 这一行要能过同步白名单,否则手机端看不到它。
        #expect(MobileSnapshotRedactor.isWireSafe(overall))
    }

    @Test("Session-scoped and unknown scope dimensions become their own rows")
    func scopedRowsOfAnyPeriodAndDimension() throws {
        let payload = """
        {
          "limits": [
            {"kind":"session","group":"session","percent":7},
            {"kind":"weekly_all","group":"weekly","percent":57},
            {"kind":"session_scoped","group":"session","percent":88,
             "scope":{"model":{"display_name":"Fable"}}},
            {"kind":"weekly_scoped","group":"weekly","percent":98,
             "scope":{"model":{"display_name":"Fable"}}},
            {"kind":"weekly_scoped","group":"weekly","percent":12,
             "scope":{"feature":{"display_name":"Cowork"}}}
          ]
        }
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        // `fable_session` 与 /usage 画面解析器产出的 ID 一致,两个来源能合并。
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable_session", "fable", "cowork"])
        #expect(quota.uniqueScopedWindows.map(\.window.windowMinutes) == [300, 10_080, 10_080])
        #expect(quota.primary.usedPercent == 7)
        #expect(quota.secondary?.usedPercent == 57)
    }

    @Test("A five-hour window that disappeared is not carried over from the cached quota")
    func vanishedSessionWindowIsNotResurrected() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-23T08:00:00Z"))
        let cached = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour": {"utilization": 70}, "seven_day": {"utilization": 30}, "seven_day_opus": {"utilization": 5}}"#.utf8),
            now: now.addingTimeInterval(-60)
        )
        let fresh = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour": null, "seven_day": {"utilization": 31}}"#.utf8),
            now: now
        )

        let merged = fresh.retainingActiveScopedWindows(from: cached, now: now)

        #expect(merged.primary.windowMinutes == 10_080)
        #expect(merged.primary.usedPercent == 31)
        #expect(merged.secondary == nil)
        // 分项行仍按原有的 15 分钟保留规则补回,账户级窗口不在其列。
        #expect(merged.uniqueScopedWindows.map(\.scopeID) == ["opus"])
        #expect(!merged.uniqueScopedWindows.contains { $0.window.windowMinutes == 300 })
    }

    @Test("The Fable lookup is the weekly model cap, not a session or surface slice of it")
    func fableWindowPrefersTheWeeklyModelCap() throws {
        // 服务端把会话分项和入口分项排在周分项前面时,`fableWindow` 仍要指向
        // 文档约定的那一条:模型级周额度 `fable`。
        let payload = """
        {
          "limits": [
            {"kind":"weekly_all","group":"weekly","percent":57},
            {"kind":"session_scoped","group":"session","percent":88,
             "scope":{"model":{"display_name":"Fable"}}},
            {"kind":"weekly_scoped","group":"weekly","percent":40,
             "scope":{"model":{"display_name":"Fable"},"surface":{"display_name":"Claude Code"}}},
            {"kind":"weekly_scoped","group":"weekly","percent":98,
             "scope":{"model":{"display_name":"Fable"}}}
          ]
        }
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable_session", "fable_claude_code", "fable"])
        #expect(quota.uniqueScopedWindows.map(\.displayName) == ["Fable", "Fable · Claude Code", "Fable"])
        let fable = try #require(quota.fableWindow)
        #expect(fable.scopeID == "fable")
        #expect(fable.window.windowMinutes == 10_080)
        #expect(fable.window.usedPercent == 98)
    }

    @Test("A row that cannot be classified never stands in for an account-wide window")
    func unclassifiableRowsAreSkippedNotPromoted() throws {
        // 三种都带百分比:横幅、没有名字的分项、没见过的限定词。它们排在真正的
        // 周总量之前,任何一条被当成账户级窗口都会把周额度显示错。
        let payload = """
        {
          "limits": [
            {"kind":"weekly_notice","group":"weekly","percent":100,"label":"Learn more"},
            {"kind":"weekly_scoped","group":"weekly","percent":99,"scope":null},
            {"kind":"weekly_bonus","group":"weekly","percent":98},
            {"kind":"mystery","group":"unknown","percent":97},
            {"kind":"weekly_all","group":"weekly","percent":31},
            {"kind":"weekly_scoped","group":"weekly","percent":64,
             "scope":{"model":{"display_name":"Fable"}}},
            {"kind":"weekly_promo","group":"weekly","percent":3,
             "scope":{"model":{"display_name":"Fable"}}}
          ]
        }
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        #expect(quota.primary.windowMinutes == 10_080)
        #expect(quota.primary.usedPercent == 31)
        #expect(quota.secondary == nil)
        // 没见过的 kind 即使带着模型名,也不能覆盖这个模型真正的额度行。
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable"])
        #expect(quota.fableWindow?.window.usedPercent == 64)
    }

    @Test("An explicit all-models row stays account-wide even with a scope attached")
    func explicitGeneralRowIgnoresScope() throws {
        let payload = """
        {"limits": [
          {"kind":"session","group":"session","percent":7},
          {"kind":"weekly_all","group":"weekly","percent":57,
           "scope":{"surface":{"display_name":"All surfaces"}}}
        ]}
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        #expect(quota.primary.usedPercent == 7)
        #expect(quota.secondary?.usedPercent == 57)
        #expect(quota.uniqueScopedWindows.isEmpty)
    }

    @Test("A structured row may name its period the legacy way")
    func structuredRowWithDurationKind() throws {
        let payload = #"{"limits": [{"kind":"one_day","group":"daily","percent":20}, {"kind":"weekly_all","group":"weekly","percent":40}]}"#
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        #expect(quota.primary.windowMinutes == 1_440)
        #expect(quota.secondary?.windowMinutes == 10_080)
    }

    @Test("Only unclassifiable rows is still an unrecognized response")
    func onlyUnclassifiableRowsReject() {
        let payload = #"{"limits": [{"kind":"weekly_bonus","group":"weekly","percent":98}, {"kind":"mystery","percent":97}]}"#
        #expect(throws: ClaudeOAuthUsageService.APIError.self) {
            try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        }
    }

    @Test("Legacy and structured sources agree on one window instead of doubling it")
    func legacyValueWinsForTheSameWindow() throws {
        let payload = """
        {
          "five_hour": {"utilization": 12.5, "resets_at": "2026-11-23T12:00:00Z"},
          "seven_day": {"utilization": 34.25},
          "limits": [
            {"kind":"session","group":"session","percent":13},
            {"kind":"weekly_all","group":"weekly","percent":34}
          ]
        }
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        // 旧字段带未取整的值和重置时间,保持原有显示。
        #expect(quota.primary.usedPercent == 12.5)
        #expect(quota.primary.resetsAt != nil)
        #expect(quota.secondary?.usedPercent == 34.25)
        #expect(quota.uniqueScopedWindows.isEmpty)
    }

    @Test("The schema summary names fields and row kinds but never a value")
    func schemaSummaryCarriesNoValues() throws {
        let payload = """
        {
          "five_hour": null,
          "seven_day": {"utilization": 41.75, "resets_at": "2026-11-27T05:00:00Z"},
          "account_email": "person@example.com",
          "weird key with spaces and 中文": 987654,
          "extra_usage": {"is_enabled": true, "used_credits": 123456, "monthly_limit": 500000},
          "limits": [
            {"kind":"weekly_all","group":"weekly","percent":41,"resets_at":"2026-11-27T05:00:00Z"},
            {"kind":"weekly_scoped","group":"weekly","percent":63,
             "scope":{"model":{"display_name":"Secret Model 777"}}},
            {"kind":"person@example.com","group":"weekly"}
          ]
        }
        """
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        let summary = ClaudeOAuthUsageParser.schemaSummary(of: object)

        #expect(summary.contains("five_hour=null"))
        #expect(summary.contains("seven_day={%}"))
        #expect(summary.contains("limits=[3]"))
        #expect(summary.contains("weekly_scoped/weekly[model]"))
        for leaked in ["41", "63", "123456", "500000", "987654", "2026", "@", "Secret", "777", "中文", "weird", "person", "example"] {
            #expect(!summary.contains(leaked), "leaked \(leaked) in \(summary)")
        }
    }

    @Test("A session window still leads when both general windows are present")
    func sessionStillLeadsWhenPresent() throws {
        let payload = #"{"five_hour": {"utilization": 0, "resets_at": null}, "seven_day": {"utilization": 40}}"#
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))

        // 刚重置的 0% 会话窗是真实读数,不能被当成"没有会话窗"。
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.usedPercent == 0)
        #expect(quota.secondary?.windowMinutes == 10_080)
    }

    @Test("Utilization is clamped into 0...100")
    func clampsUtilization() throws {
        let payload = #"{"five_hour": {"utilization": 120}}"#
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 100)
    }

    @Test("Plan name falls back to bare subscription type without a tier")
    func planNameWithoutTier() {
        #expect(ClaudeOAuthUsageParser.planName(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
        #expect(ClaudeOAuthUsageParser.planName(subscriptionType: nil, rateLimitTier: "20x") == nil)
        #expect(ClaudeOAuthUsageParser.planName(subscriptionType: "max", rateLimitTier: "default_5x") == "Max 5x")
    }
}

@Suite("Claude credentials reader")
struct ClaudeCredentialsReaderTests {
    @Test("Parses Claude Code credentials JSON")
    func parsesCredentials() {
        let payload = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-test",
            "refreshToken": "sk-ant-ort01-test",
            "expiresAt": 9999999999999,
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x"
          }
        }
        """
        let credentials = ClaudeCredentialsReader.parse(payload)
        #expect(credentials?.accessToken == "sk-ant-oat01-test")
        #expect(credentials?.subscriptionType == "max")
        #expect(credentials?.rateLimitTier == "default_claude_max_20x")
    }

    @Test("An expired token is skipped instead of being sent to the API")
    func skipsExpiredToken() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let expiredMs = (now.timeIntervalSince1970 + 30) * 1000
        let payload = """
        {"claudeAiOauth": {"accessToken": "sk-ant-oat01-test", "expiresAt": \(expiredMs)}}
        """
        #expect(ClaudeCredentialsReader.parse(payload, now: now) == nil)
    }

    @Test("A token without expiresAt is accepted as-is")
    func acceptsTokenWithoutExpiry() {
        let payload = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-test"}}"#
        #expect(ClaudeCredentialsReader.parse(payload)?.accessToken == "sk-ant-oat01-test")
    }

    @Test("Custom CLAUDE_CONFIG_DIR uses a SHA-256-prefixed keychain service")
    func scopedKeychainServiceName() {
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(
            ClaudeCredentialsReader.keychainServiceName(
                configurationDirectory: nil,
                homeDirectory: home
            ) == ClaudeCredentialsReader.keychainService
        )
        #expect(
            ClaudeCredentialsReader.keychainServiceName(
                configurationDirectory: "/Users/example/.claude",
                homeDirectory: home
            ) == ClaudeCredentialsReader.keychainService
        )
        #expect(
            ClaudeCredentialsReader.keychainServiceName(
                configurationDirectory: "~/.claude",
                homeDirectory: home
            ) == ClaudeCredentialsReader.keychainService
        )
        #expect(
            ClaudeCredentialsReader.keychainServiceName(
                configurationDirectory: "/tmp/tokenremain-claude-account/",
                homeDirectory: home
            ) == "Claude Code-credentials-7ebe5f89"
        )
    }

    @Test("Reads the credentials file from CLAUDE_CONFIG_DIR before the keychain")
    func readsConfigDirFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-file"}}"#
        try Data(payload.utf8).write(to: directory.appendingPathComponent(".credentials.json"))

        var reader = ClaudeCredentialsReader()
        reader.environment = ["CLAUDE_CONFIG_DIR": directory.path]
        reader.keychainPayload = { _, _ in
            Issue.record("keychain must not be consulted when the file already answers")
            return KeychainRead.Outcome(payload: nil, status: errSecItemNotFound)
        }
        #expect(reader.load()?.accessToken == "sk-ant-oat01-file")
    }

    @Test("Falls through to the keychain when no credentials file exists")
    func fallsBackToKeychain() {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(
                payload: #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-keychain"}}"#,
                status: errSecSuccess
            )
        }
        #expect(reader.load()?.accessToken == "sk-ant-oat01-keychain")
    }

    @Test("An isolated managed account never inherits the system Claude credential")
    func managedAccountDoesNotFallBack() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-managed-missing-\(UUID().uuidString)")
            .path
        let scopedService = ClaudeCredentialsReader.keychainServiceName(
            configurationDirectory: directory
        )
        let observedService = ClaudeLockedValue<String?>(nil)
        var reader = ClaudeCredentialsReader()
        reader.environment = ["CLAUDE_CONFIG_DIR": directory]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-system-home-\(UUID().uuidString)")
        reader.fallbackToDefaultDirectory = false
        reader.keychainPayload = { service, _ in
            observedService.set(service)
            return KeychainRead.Outcome(
                payload: #"{"claudeAiOauth": {"accessToken": "scoped-token"}}"#,
                status: errSecSuccess
            )
        }

        #expect(scopedService != ClaudeCredentialsReader.keychainService)
        #expect(reader.load()?.accessToken == "scoped-token")
        #expect(observedService.get() == scopedService)
    }

    /// 这两个只验证"意图有没有传到 KeychainRead 门口"。禁止交互究竟有没有生效
    /// 是 `KeychainReadTests` 的职责 —— 上一版回归时,恰恰是这一层全绿而那一层
    /// 根本没被测到。
    @Test("Background fallback asks for a non-interactive keychain read")
    func backgroundFallbackIsNoninteractive() {
        let observed = ClaudeLockedValue<KeychainRead.Interaction?>(nil)
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { _, interaction in
            observed.set(interaction)
            return KeychainRead.Outcome(
                payload: #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-keychain"}}"#,
                status: errSecSuccess
            )
        }

        #expect(reader.load()?.accessToken == "sk-ant-oat01-keychain")
        #expect(observed.get() == .disallowed)
    }

    @Test("An explicit user action may opt into Keychain interaction")
    func explicitActionCanAllowInteraction() {
        let observed = ClaudeLockedValue<KeychainRead.Interaction?>(nil)
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { _, interaction in
            observed.set(interaction)
            return KeychainRead.Outcome(
                payload: #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-keychain"}}"#,
                status: errSecSuccess
            )
        }

        #expect(
            reader.load(keychainInteraction: .allowed)?.accessToken
                == "sk-ant-oat01-keychain"
        )
        #expect(observed.get() == .allowed)
    }

    /// 凭据不可用时 `fetch()` 必须抛错让 `ClaudeUsageService` 走 PTY 兜底,
    /// 而不是把刷新任务卡在钥匙串上。
    @Test("Unavailable credentials surface as nil so the fallback chain can engage")
    func unavailableCredentialsYieldNil() {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(payload: nil, status: errSecItemNotFound)
        }
        #expect(reader.load() == nil)
    }

    @Test("A blocked Claude keychain item requests explicit authorization")
    func keychainAuthorizationStatus() {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-claude-auth-required")
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(payload: nil, status: errSecInteractionNotAllowed)
        }
        let result = reader.read()
        #expect(result.credentials == nil)
        #expect(result.needsAuthorization)
    }

    @Test("A readable unknown Claude keychain schema is classified as invalid")
    func invalidKeychainSchema() {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-claude-invalid")
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(payload: #"{"future":true}"#, status: errSecSuccess)
        }
        let result = reader.read()
        #expect(result.credentials == nil)
        #expect(result.hasInvalidKeychainPayload)
        #expect(!result.needsAuthorization)
    }

    @Test("An expired readable Claude credential is not called malformed")
    func expiredKeychainCredential() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let expiredMs = (now.timeIntervalSince1970 - 60) * 1000
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-claude-expired")
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(
                payload: #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":\#(expiredMs)}}"#,
                status: errSecSuccess
            )
        }
        let result = reader.read(now: now)
        #expect(result.credentials == nil)
        #expect(result.hasExpiredCredentials)
        #expect(!result.hasInvalidKeychainPayload)
    }
}

/// Claude Code 的钥匙串条目 partition list 只有 `apple-tool:`,所以本应用无论被
/// 授权多少次都读不到它 —— 实测那条条目已经信任了四代本应用,依旧每次拒绝。
/// 这条委托路径决定了限额走 API 直查还是 20 秒的 PTY 抓屏,它的边界必须钉住:
/// 直查已经成功、条目根本不存在、以及托管账户,三种情况都不该动用委托。
@Suite("Claude credentials Apple tool delegate")
struct ClaudeAppleToolDelegateTests {
    private static let usablePayload = """
    {"claudeAiOauth": {"accessToken": "sk-ant-oat01-delegated", \
    "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"}}
    """

    private func reader(
        keychain: KeychainRead.Outcome,
        delegate: KeychainRead.Outcome,
        delegateConsulted: ClaudeLockedValue<Bool>
    ) -> ClaudeCredentialsReader {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { _, _ in keychain }
        reader.appleToolPayload = { _ in
            delegateConsulted.set(true)
            return delegate
        }
        return reader
    }

    @Test("A partition refusal is retried through the Apple tool instead of degrading")
    func delegatesWhenThePartitionLocksTheAppOut() async {
        let consulted = ClaudeLockedValue(false)
        let reader = reader(
            keychain: KeychainRead.Outcome(payload: nil, status: errSecAuthFailed),
            delegate: KeychainRead.Outcome(payload: Self.usablePayload, status: errSecSuccess),
            delegateConsulted: consulted
        )

        let result = await reader.readAllowingAppleTool()

        #expect(consulted.get())
        #expect(result.credentials?.accessToken == "sk-ant-oat01-delegated")
        // 计划名只有直查路径会写出来,它是"没走抓屏"的凭据。
        #expect(result.credentials?.subscriptionType == "max")
        #expect(result.credentials?.rateLimitTier == "default_claude_max_5x")
        #expect(result.source == .keychain)
    }

    @Test("A direct read that already works never spawns the Apple tool")
    func skipsDelegateWhenDirectReadSucceeds() async {
        let consulted = ClaudeLockedValue(false)
        let reader = reader(
            keychain: KeychainRead.Outcome(payload: Self.usablePayload, status: errSecSuccess),
            delegate: KeychainRead.Outcome(payload: nil, status: errSecItemNotFound),
            delegateConsulted: consulted
        )

        let result = await reader.readAllowingAppleTool()

        #expect(result.credentials != nil)
        #expect(consulted.get() == false)
    }

    @Test("A missing item is not an authorization problem and needs no delegate")
    func skipsDelegateWhenTheItemIsAbsent() async {
        let consulted = ClaudeLockedValue(false)
        let reader = reader(
            keychain: KeychainRead.Outcome(payload: nil, status: errSecItemNotFound),
            delegate: KeychainRead.Outcome(payload: Self.usablePayload, status: errSecSuccess),
            delegateConsulted: consulted
        )

        let result = await reader.readAllowingAppleTool()

        #expect(result.credentials == nil)
        #expect(consulted.get() == false)
    }

    /// Claude Code 2.1+ stores a second account under
    /// `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[:8]>`. Delegating to
    /// the unsuffixed system item would show someone else's quota.
    @Test("An isolated managed account delegates only to its scoped keychain item")
    func managedProfileDelegatesToScopedKeychain() async {
        let directory = "/tmp/tokenremain-claude-account"
        let expectedService = ClaudeCredentialsReader.keychainServiceName(
            configurationDirectory: directory
        )
        let observed = ClaudeLockedValue<String?>(nil)
        var reader = ClaudeCredentialsReader()
        reader.environment = ["CLAUDE_CONFIG_DIR": directory]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-system-home-\(UUID().uuidString)")
        reader.fallbackToDefaultDirectory = false
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(payload: nil, status: errSecAuthFailed)
        }
        reader.appleToolPayload = { service in
            observed.set(service)
            return KeychainRead.Outcome(payload: Self.usablePayload, status: errSecSuccess)
        }

        let result = await reader.readAllowingAppleTool()

        #expect(expectedService == "Claude Code-credentials-7ebe5f89")
        #expect(expectedService != ClaudeCredentialsReader.keychainService)
        #expect(observed.get() == expectedService)
        #expect(result.credentials?.accessToken == "sk-ant-oat01-delegated")
        #expect(result.source == .keychain)
    }

    @Test("An expired delegated token is reported as expired, not as usable")
    func reportsExpiredDelegatedToken() async {
        let expired = Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1000
        let payload = """
        {"claudeAiOauth": {"accessToken": "sk-ant-oat01-stale", "expiresAt": \(Int(expired))}}
        """
        let consulted = ClaudeLockedValue(false)
        let reader = reader(
            keychain: KeychainRead.Outcome(payload: nil, status: errSecAuthFailed),
            delegate: KeychainRead.Outcome(payload: payload, status: errSecSuccess),
            delegateConsulted: consulted
        )

        let result = await reader.readAllowingAppleTool()

        #expect(consulted.get())
        #expect(result.credentials == nil)
        #expect(result.hasExpiredCredentials)
    }
}

private final class ClaudeLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Claude oauth/usage transport retry")
struct ClaudeOAuthUsageTransportRetryTests {
    private static func response(_ status: Int) -> (Data, URLResponse) {
        let http = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), http)
    }

    @Test("Classifies link-level URL errors as transport failures")
    func transportFailureClassification() {
        #expect(ClaudeOAuthUsageService.isTransportFailure(URLError(.timedOut)))
        #expect(ClaudeOAuthUsageService.isTransportFailure(URLError(.networkConnectionLost)))
        #expect(ClaudeOAuthUsageService.isTransportFailure(URLError(.notConnectedToInternet)))
        #expect(!ClaudeOAuthUsageService.isTransportFailure(URLError(.badServerResponse)))
        #expect(!ClaudeOAuthUsageService.isTransportFailure(URLError(.cancelled)))
        #expect(!ClaudeOAuthUsageService.isTransportFailure(ClaudeOAuthUsageService.APIError.invalidResponse))
    }

    @Test("A single transport timeout is retried once and the retry result wins")
    func retriesOnceAfterTimeout() async throws {
        var attempts = 0
        let request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        let (_, response) = try await ClaudeOAuthUsageService.performWithOneTransportRetry(
            request,
            retryDelay: 0
        ) { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return Self.response(200)
        }
        #expect(attempts == 2)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("Two consecutive transport failures give up with the second error")
    func retriesOnlyOnce() async {
        var attempts = 0
        let request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        await #expect(throws: URLError.self) {
            _ = try await ClaudeOAuthUsageService.performWithOneTransportRetry(
                request,
                retryDelay: 0
            ) { _ in
                attempts += 1
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(attempts == 2)
    }

    @Test("Non-transport errors are not retried")
    func doesNotRetryOtherErrors() async {
        var attempts = 0
        let request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        await #expect(throws: URLError.self) {
            _ = try await ClaudeOAuthUsageService.performWithOneTransportRetry(
                request,
                retryDelay: 0
            ) { _ in
                attempts += 1
                throw URLError(.badServerResponse)
            }
        }
        #expect(attempts == 1)
    }

    @Test("The request timeout leaves room for one retry inside a refresh round")
    func timeoutBudget() {
        #expect(ClaudeOAuthUsageService.requestTimeout == 25)
        #expect(ClaudeOAuthUsageService.transportRetryDelay == 2)
        #expect(2 * ClaudeOAuthUsageService.requestTimeout + ClaudeOAuthUsageService.transportRetryDelay < AdaptiveRefreshPolicy.activeInterval)
    }

    @Test("Cancellation during a failed request prevents a transport retry")
    func cancellationPreventsRetry() async {
        let attempt = Task {
            var calls = 0
            do {
                _ = try await ClaudeOAuthUsageService.performWithOneTransportRetry(
                    URLRequest(url: URL(string: "https://unused.invalid")!), retryDelay: 0
                ) { _ in
                    calls += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw URLError(.timedOut)
                }
                Issue.record("A cancelled read must throw")
            } catch { #expect(error is CancellationError) }
            return calls
        }
        #expect(await attempt.value == 1)
    }

    @Test("Cancellation rejects a late successful response")
    func cancellationRejectsLateSuccess() async {
        let attempt = Task {
            do {
                _ = try await ClaudeOAuthUsageService.performWithOneTransportRetry(
                    URLRequest(url: URL(string: "https://unused.invalid")!), retryDelay: 0
                ) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return Self.response(200)
                }
                Issue.record("A late response must not become a successful read")
            } catch { #expect(error is CancellationError) }
        }
        await attempt.value
    }

    @Test("Cancelling a credential reread cannot issue an OAuth request")
    func cancellationBeforeTokenChangeRetry() async {
        let attempt = Task {
            do {
                _ = try await ClaudeUsageService.retryOAuthAfterCredentialRefresh(
                    previousAccessToken: "old-fixture",
                    readCurrentAccessToken: {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return "new-fixture"
                    },
                    fetchOAuthUsage: {
                        Issue.record("Cancelled recovery must not make another request")
                        throw URLError(.badServerResponse)
                    }
                )
                Issue.record("Cancelled recovery must throw")
            } catch { #expect(error is CancellationError) }
        }
        await attempt.value
    }
}

@Suite("Claude signed-out keychain payloads")
struct ClaudeSignedOutPayloadTests {
    @Test("Signed-out managed profiles retain the scoped Keychain identity")
    func managedSignedOutReadStaysScoped() async {
        var reader = ClaudeCredentialsReader()
        let directory = "/tmp/claude-scoped-signout-\(UUID().uuidString)"
        reader.environment = ["CLAUDE_CONFIG_DIR": directory]
        reader.fallbackToDefaultDirectory = false
        let service = ClaudeCredentialsReader.keychainServiceName(configurationDirectory: directory)
        reader.keychainPayload = { requested, _ in
            #expect(requested == service)
            return KeychainRead.Outcome(payload: nil, status: errSecAuthFailed)
        }
        reader.appleToolPayload = { requested in
            #expect(requested == service)
            return KeychainRead.Outcome(payload: #"{"mcpOAuth":{}}"#, status: errSecSuccess)
        }
        let result = await reader.readAllowingAppleTool()
        #expect(result.keychainPayloadIsSignedOut)
        #expect(!result.needsAuthorization)
        #expect(result.credentials == nil)
    }

    @Test("A payload that only carries MCP OAuth state means Claude Code is signed out")
    func mcpOnlyPayloadIsSignedOut() {
        #expect(ClaudeCredentialsReader.isSignedOutPayload(#"{"mcpOAuth": {"server": {"accessToken": "x"}}}"#))
        #expect(ClaudeCredentialsReader.isSignedOutPayload(#"{"claudeAiOauth": {"accessToken": ""}}"#))
        #expect(!ClaudeCredentialsReader.isSignedOutPayload(#"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-x"}}"#))
        #expect(!ClaudeCredentialsReader.isSignedOutPayload("not json"))
    }

    @Test("The direct keychain read reports a signed-out payload instead of an invalid one")
    func directReadClassifiesSignedOut() {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-claude-signed-out")
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(payload: #"{"mcpOAuth": {}}"#, status: errSecSuccess)
        }
        let result = reader.read()
        #expect(result.credentials == nil)
        #expect(result.hasInvalidKeychainPayload)
        #expect(result.keychainPayloadIsSignedOut)

        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(payload: "garbage", status: errSecSuccess)
        }
        let garbage = reader.read()
        #expect(garbage.hasInvalidKeychainPayload)
        #expect(!garbage.keychainPayloadIsSignedOut)
    }

    @Test("A signed-out payload behind the Apple tool no longer reads as an authorization problem")
    func appleToolReadClassifiesSignedOut() async {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-claude-signed-out-tool")
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(payload: nil, status: errSecAuthFailed)
        }
        reader.appleToolPayload = { _ in
            KeychainRead.Outcome(payload: #"{"mcpOAuth": {}}"#, status: errSecSuccess)
        }
        let result = await reader.readAllowingAppleTool()
        #expect(!result.needsAuthorization)
        #expect(result.hasInvalidKeychainPayload)
        #expect(result.keychainPayloadIsSignedOut)
    }
}
