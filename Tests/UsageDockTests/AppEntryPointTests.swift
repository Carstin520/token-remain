import AppKit
import Testing
@testable import UsageDock

@Suite("App entry point")
@MainActor
struct AppEntryPointTests {
    @Test("A Dock click never falls through to the system's default reopen")
    func reopenIsHandledByTheApp() {
        let delegate = AppDelegate()
        #expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
    }

    @Test("A system-opened placeholder Settings window hides and closes without navigating")
    func placeholderSettingsWindowCloses() async throws {
        let counter = NotificationCounter(name: .tokenRemainOpenSettings)
        defer { counter.stop() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = SettingsPlaceholderCloser.CloserView()
        window.orderFront(nil)

        #expect(window.alphaValue == 0)
        for _ in 0..<50 where window.isVisible {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!window.isVisible)
        #expect(counter.count == 0)
    }
}

@MainActor
private final class NotificationCounter {
    private(set) var count = 0
    private var observer: NSObjectProtocol?

    init(name: Notification.Name) {
        observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    func stop() {
        observer.map(NotificationCenter.default.removeObserver)
    }
}
