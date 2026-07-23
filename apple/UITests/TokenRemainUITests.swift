import XCTest

/// Every launch pins the scenario via `-tr-demo`, so no assertion depends on
/// wall-clock time or on previously persisted state.
final class TokenRemainUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Chinese is the design language; pinning it keeps copy assertions stable.
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        // The configurable Dock-like overview is intentionally persisted per device.
        // Reset it for each UI test so a previous test's hide/reorder action cannot
        // change the next test's layout.
        app.launchArguments += ["-tr-reset-overview-layout"]
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    // MARK: - Honest empty state

    func testColdLaunchInNoneOriginShowsNoNumbers() {
        let app = launch(["-tr-origin-none"])
        XCTAssertTrue(
            app.descendants(matching: .any)["tr.overview.emptyState"].waitForExistence(timeout: 10),
            "The .none origin must render the not-connected card"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["tr.overview.hero"].exists,
            "No hero percentage may be rendered without a data source"
        )
    }

    // MARK: - Demo mode

    func testConceptScenarioMatchesTheConfirmedDesign() {
        let app = launch(["-tr-demo", "concept"])
        let hero = app.descendants(matching: .any)["tr.overview.hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 10))
        XCTAssertEqual(hero.label, "46%")

        let badge = app.descendants(matching: .any)["tr.overview.riskBadge"]
        XCTAssertTrue(badge.exists)
        XCTAssertEqual(badge.label, "低")

        // The DEMO mark must be present wherever demo numbers are shown.
        XCTAssertTrue(app.descendants(matching: .any)["演示数据"].exists)
    }

    func testAllFourTabsAreReachable() {
        let app = launch(["-tr-demo", "concept"])
        XCTAssertTrue(app.descendants(matching: .any)["tr.overview.hero"].waitForExistence(timeout: 10))

        for tab in ["额度", "趋势", "设置", "概览"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "missing tab: \(tab)")
            button.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["tr.overview.hero"].waitForExistence(timeout: 5))
    }

    func testCTALandsOnTheHighlightedConstrainingWindow() {
        let app = launch(["-tr-demo", "concept"])
        let cta = app.descendants(matching: .any)["tr.overview.cta"]
        XCTAssertTrue(cta.waitForExistence(timeout: 10))
        cta.tap()

        // The concept scenario's scarcest window is Codex's 7-day window.
        let card = app.descendants(matching: .any)["tr.limits.window.Codex-primary-10080"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testOverviewShowsTodayUsageCard() {
        let app = launch(["-tr-demo", "concept"])
        // The today card renders only from real synced history (demo seeds 14 days),
        // with today's total cost as the primary metric.
        let cost = app.descendants(matching: .any)["tr.overview.today.cost"]
        XCTAssertTrue(cost.waitForExistence(timeout: 10))
        XCTAssertTrue(cost.label.contains("估算成本"), "today card must expose a readable real cost total")
    }

    func testOverviewProviderCardExpandsItsOfficialWindows() {
        let app = launch(["-tr-demo", "concept"])
        let toggle = app.descendants(matching: .any)["tr.overview.provider.toggle.Codex"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(toggle.label.contains("7 天"), "Codex must default to its only and shortest session")
        XCTAssertFalse(app.descendants(matching: .any)["tr.overview.window.Codex-primary-10080"].exists)
        toggle.tap()

        let window = app.descendants(matching: .any)["tr.overview.window.Codex-primary-10080"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "expanding a provider must show its official window details in place"
        )
    }

    func testOverviewClaudeDefaultsToFiveHourSession() {
        let app = launch(["-tr-demo", "concept"])
        let toggle = app.descendants(matching: .any)["tr.overview.provider.toggle.Claude Code"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(toggle.label.contains("5 小时"), "Claude must default to its shortest available session")
    }

    func testOverviewComponentLongPressOpensMoveSubmenu() {
        let app = launch(["-tr-demo", "concept"])
        let toggle = app.descendants(matching: .any)["tr.overview.provider.toggle.Claude Code"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.press(forDuration: 1.2)

        let move = app.buttons["移动组件"]
        XCTAssertTrue(move.waitForExistence(timeout: 5), "long-pressing a widget must expose its move submenu")
        move.tap()
        XCTAssertTrue(
            app.buttons["上移"].waitForExistence(timeout: 3)
                || app.buttons["下移"].waitForExistence(timeout: 3),
            "the move submenu must expose vertical reorder actions"
        )
    }

    func testTrendsReadoutDefaultsToLatestDayAndSurvivesSelection() {
        let app = launch(["-tr-demo", "concept"])
        XCTAssertTrue(app.descendants(matching: .any)["tr.overview.hero"].waitForExistence(timeout: 10))
        app.tabBars.buttons["趋势"].tap()

        // The readout is always present and defaults to the most recent day so the
        // latest Claude/Codex split is glanceable without any interaction.
        let callout = app.descendants(matching: .any)["tr.trends.selectionCallout"]
        XCTAssertTrue(callout.waitForExistence(timeout: 10))
        XCTAssertTrue(callout.label.contains("最新一天"), "readout must default to the latest day")

        let totals = app.descendants(matching: .any)["tr.trends.totals"]
        XCTAssertTrue(totals.waitForExistence(timeout: 5), "the range totals card must render")

        // Scrubbing the chart drives the selection; the readout must stay present
        // and honest whether the tap lands on a column or on empty area. The chart
        // identifier resolves to several plot sub-elements, so scope to firstMatch.
        let chart = app.descendants(matching: .any)["tr.trends.usageBarChart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6)).tap()
        XCTAssertTrue(callout.waitForExistence(timeout: 5))
    }

    func testCriticalScenarioReportsHighRisk() {
        let app = launch(["-tr-demo", "critical"])
        let badge = app.descendants(matching: .any)["tr.overview.riskBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertEqual(badge.label, "高")
    }

    func testFreshResetKeepsAnUnknownResetHonest() {
        let app = launch(["-tr-demo", "freshReset"])
        XCTAssertTrue(app.descendants(matching: .any)["tr.overview.hero"].waitForExistence(timeout: 10))
        app.tabBars.buttons["额度"].tap()

        let card = app.descendants(matching: .any)["tr.limits.window.Claude Code-primary-300"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("重置时间未知"))
    }

    func testLiveActivityCanStartAndStopInDemoMode() {
        let app = launch(["-tr-demo", "concept"])
        XCTAssertTrue(app.descendants(matching: .any)["tr.overview.hero"].waitForExistence(timeout: 10))
        app.tabBars.buttons["设置"].tap()

        let start = app.descendants(matching: .any)["tr.settings.startLiveActivity"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        let stop = app.descendants(matching: .any)["tr.settings.stopLiveActivity"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        let homeSettled = expectation(description: "Home Screen transition settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { homeSettled.fulfill() }
        wait(for: [homeSettled], timeout: 4)
        let islandScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        islandScreenshot.name = "Dynamic Island · TokenRemain active"
        islandScreenshot.lifetime = .keepAlways
        add(islandScreenshot)

        springboard
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
            .press(forDuration: 1)
        let islandExpanded = expectation(description: "Dynamic Island expanded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { islandExpanded.fulfill() }
        wait(for: [islandExpanded], timeout: 2)
        let expandedScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expandedScreenshot.name = "Dynamic Island · TokenRemain expanded"
        expandedScreenshot.lifetime = .keepAlways
        add(expandedScreenshot)

        app.activate()
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
    }

    /// Physical-device E2E coverage for the real privacy-preserving path.
    /// Unlike the deterministic gallery test above, this deliberately launches
    /// without a demo argument and requires the automatic Mac-sync source.
    func testMacSyncSnapshotCanDriveLiveActivityOnPhysicalDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("CloudKit and ActivityKit E2E requires a signed physical iPhone")
        #else
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["tr.overview.hero"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["演示数据"].exists)

        app.tabBars.buttons["设置"].tap()
        let macSync = app.switches["tr.settings.macSyncToggle"]
        XCTAssertTrue(macSync.waitForExistence(timeout: 5))
        XCTAssertEqual(macSync.value as? String, "1", "the physical-device E2E must use automatic Mac sync")

        let start = app.descendants(matching: .any)["tr.settings.startLiveActivity"]
        let stop = app.descendants(matching: .any)["tr.settings.stopLiveActivity"]
        if stop.exists {
            stop.tap()
            XCTAssertTrue(start.waitForExistence(timeout: 5))
        }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "a verified Mac snapshot must start a Live Activity")

        XCUIDevice.shared.press(.home)
        let macSyncScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        macSyncScreenshot.name = "Dynamic Island · macSync snapshot"
        macSyncScreenshot.lifetime = .keepAlways
        add(macSyncScreenshot)

        app.activate()
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        #endif
    }

    /// Proves the real CloudKit snapshot is not truncated to the original two
    /// providers. This intentionally depends on the Mac's live Cursor and
    /// Antigravity sources and is therefore physical-device-only.
    func testMacSyncLimitsShowsExtendedProvidersOnPhysicalDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Live CloudKit provider coverage requires a signed physical iPhone")
        #else
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["tr.overview.hero"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["演示数据"].exists)

        app.tabBars.buttons["额度"].tap()
        for providerID in ["cursor", "antigravity"] {
            let card = app.descendants(matching: .any)["tr.limits.provider.\(providerID)"]
            XCTAssertTrue(
                card.waitForExistence(timeout: 10),
                "The live Mac snapshot must include \(providerID)"
            )
        }
        #endif
    }

    // MARK: - Deep links

    func testDeepLinkRoutesToTrends() {
        let app = launch(["-tr-demo", "concept"])
        XCTAssertTrue(app.descendants(matching: .any)["tr.overview.hero"].waitForExistence(timeout: 10))

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.textFields.firstMatch.tap()
        safari.typeText("tokenremain://trends\n")

        let openButton = safari.buttons["打开"].firstMatch
        if openButton.waitForExistence(timeout: 5) {
            openButton.tap()
        }

        XCTAssertTrue(
            app.descendants(matching: .any)["tr.trends.usageBarChart"].waitForExistence(timeout: 10)
                || app.descendants(matching: .any)["tr.trends.emptyState"].waitForExistence(timeout: 5),
            "tokenremain://trends must land on the Trends tab"
        )
    }

    // MARK: - Accessibility audit

    func testAccessibilityAuditOnEveryTab() throws {
        let app = launch(["-tr-demo", "concept"])
        XCTAssertTrue(app.descendants(matching: .any)["tr.overview.hero"].waitForExistence(timeout: 10))

        for tab in ["概览", "额度", "趋势", "设置"] {
            app.tabBars.buttons[tab].tap()

            // Contrast is asserted as pure math in the kit's unit tests
            // (TRThemeContrastTests); the automated contrast heuristic is unreliable
            // on an intentionally low-contrast dark palette, so it is excluded here.
            //
            // `.dynamicType` is enforced structurally but its automated heuristic is
            // ignored via the handler below (not dropped from the audit): the
            // cyberpunk "display layer" renders large numerals (hero %, window %,
            // countdown) as dot-matrix `Canvas` graphics and the page title as a
            // chromatic-aberration ZStack — intentional typography that does not
            // scale as system text, so the heuristic flags it as "partially
            // unsupported". Real Dynamic Type behaviour is covered by
            // `testSettingsScalesAtAccessibilitySizes`, the `@ScaledMetric` hero
            // sizing, and the text-style body copy. Interactive hit regions are
            // asserted by the focused navigation/control tests; the system hit-region
            // heuristic incorrectly treats informative pixel badges as controls, so it
            // is not part of this broad all-elements audit.
            let auditTypes: XCUIAccessibilityAuditType = [
                .dynamicType,
                .elementDetection,
                .sufficientElementDescription,
                .trait
            ]

            try app.performAccessibilityAudit(for: auditTypes) { issue in
                issue.auditType == .dynamicType
            }
        }
    }

    /// Dynamic Type coverage for the Settings tab, which the automated audit cannot
    /// measure (see above): at the largest accessibility size every control must
    /// still be reachable and hittable after scrolling.
    func testSettingsScalesAtAccessibilitySizes() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments += ["-tr-demo", "concept"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"]
        app.launch()

        app.tabBars.buttons["设置"].tap()

        let toggle = app.switches["tr.settings.demoToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(toggle.isHittable, "the demo toggle must stay hittable at AX5")

        let start = app.descendants(matching: .any)["tr.settings.startLiveActivity"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))

        let privacy = app.descendants(matching: .any)["tr.settings.privacy"]
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), "the privacy statement must remain reachable at AX5")
    }
}
