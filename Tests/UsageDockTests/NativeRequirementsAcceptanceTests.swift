import AppKit
import SwiftUI
import Testing
@testable import UsageDock

/// Explicit fixture-only native acceptance. No UsageStore, Keychain, real logs,
/// background refresh, installation, or production preferences are involved.
@Suite("Native requirements acceptance", .serialized)
@MainActor
struct NativeRequirementsAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENREMAIN_NATIVE_ACCEPTANCE"] == "1"))
    func priceCardsScrollWithTheirPage() async throws {
        let models = (0..<7).map { index in
            DailyUsageHistory.ModelUsage(id: "claude-long-relay-model-name-\(index)-with-extra-context",
                inputTokens: 200, outputTokens: 400, cacheTokens: 400, cost: 0.025,
                cacheReadTokens: 300, cacheCreationTokens: 100)
        }
        let day = DailyUsageHistory.Day(date: .now, agents: [.init(id: "claude", tokens: 7000, cost: 0.175, models: models)])
        let panel = PriceAnalysisPanel(days: [day], agentIDs: ["claude"], snapshot: .init(prices: [:], fetchedAt: nil))
        let host = NSHostingView(rootView: ScrollView { panel.padding(20).frame(maxWidth: .infinity) }
            .background(DashboardTheme.canvas))
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 480, height: 340),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "TokenRemain Acceptance — synthetic data"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let views = scrollViews(host)
        #expect(views.count == 1, "Model cards must not introduce a nested scroll view")
        let scroll = try #require(views.first)
        let before = scroll.contentView.bounds.origin.y
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -280, wheel2: 0, wheel3: 0))
        let wheel = try #require(NSEvent(cgEvent: cg))
        scroll.scrollWheel(with: wheel)
        try await Task.sleep(for: .milliseconds(150))
        #expect(scroll.contentView.bounds.origin.y > before, "A wheel event over the model page must move its viewport")
        window.setContentSize(NSSize(width: 760, height: 340))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(scroll.documentView!.bounds.height > scroll.contentView.bounds.height)
        if let directory = ProcessInfo.processInfo.environment["TOKENREMAIN_UI_EVIDENCE"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-price-scroll.png"))
        }
    }
}
