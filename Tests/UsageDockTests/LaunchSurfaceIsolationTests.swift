import Foundation
import Testing
@testable import UsageDock

/// 守住 issue #34 的第一环:后台刷新问"界面可见吗"的时候,一个还没建出来的
/// surface 必须能诚实回答"没有可问的",而不是被顺手建出来。
@Suite("Primary surface visibility")
struct PrimarySurfaceVisibilityTests {
    @Test("A surface that was never created can never report itself visible")
    func notCreatedIsNeverVisible() {
        #expect(!SurfaceState.notCreated.countsAsVisible)
        #expect(!SurfaceState.created(visible: false).countsAsVisible)
        #expect(SurfaceState.created(visible: true).countsAsVisible)
    }

    @Test("Background polling sees nothing visible on a fresh launch")
    func freshLaunchHasNoVisibleSurface() {
        // 这正是崩溃版本的启动瞬间:三个界面都还不存在,轮询却已经在问了。
        #expect(!PrimarySurfaceVisibility.isVisible(
            popup: .notCreated,
            dashboard: .notCreated,
            floatingWidget: .notCreated
        ))
    }

    @Test("Any one visible surface keeps the minute-level cadence alive")
    func anyVisibleSurfaceCounts() {
        #expect(PrimarySurfaceVisibility.isVisible(
            popup: .created(visible: true),
            dashboard: .notCreated,
            floatingWidget: .notCreated
        ))
        #expect(PrimarySurfaceVisibility.isVisible(
            popup: .notCreated,
            dashboard: .created(visible: true),
            floatingWidget: .created(visible: false)
        ))
        #expect(PrimarySurfaceVisibility.isVisible(
            popup: .notCreated,
            dashboard: .notCreated,
            floatingWidget: .created(visible: true)
        ))
    }

    @Test("Created but hidden surfaces do not keep background work running")
    func hiddenSurfacesDoNotCount() {
        #expect(!PrimarySurfaceVisibility.isVisible(
            popup: .created(visible: false),
            dashboard: .created(visible: false),
            floatingWidget: .created(visible: false)
        ))
    }
}

@Suite("Liquid Glass popup escape hatch")
struct LiquidGlassPopupAvailabilityTests {
    @Test("Liquid Glass is used only on a system that has it, absent an override")
    func defaultsToGlassOnSupportedSystems() {
        #expect(LiquidGlassPopupAvailability.usesLiquidGlass(
            systemSupportsLiquidGlass: true,
            forceLegacyPopover: false
        ))
        #expect(!LiquidGlassPopupAvailability.usesLiquidGlass(
            systemSupportsLiquidGlass: false,
            forceLegacyPopover: false
        ))
    }

    @Test("The override falls back to the legacy popover even on macOS 26")
    func overrideForcesLegacyPopover() {
        #expect(!LiquidGlassPopupAvailability.usesLiquidGlass(
            systemSupportsLiquidGlass: true,
            forceLegacyPopover: true
        ))
    }

    @Test("The escape hatch is off unless the user writes the key")
    func overrideDefaultsToOff() {
        let defaults = UserDefaults(suiteName: "tokenremain.tests.escape-hatch")!
        defaults.removePersistentDomain(forName: "tokenremain.tests.escape-hatch")

        #expect(!LiquidGlassPopupAvailability.forceLegacyPopover(in: defaults))

        defaults.set(true, forKey: PreferencesStore.forceLegacyPopoverKey)
        #expect(LiquidGlassPopupAvailability.forceLegacyPopover(in: defaults))

        defaults.removePersistentDomain(forName: "tokenremain.tests.escape-hatch")
    }
}
