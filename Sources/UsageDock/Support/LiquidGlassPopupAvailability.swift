import Foundation

/// Decides whether the menu-bar popup uses the macOS 26 Liquid Glass panel or
/// the legacy `NSPopover`.
///
/// The override exists because 1.3.0-1.3.4 shipped a crash that made the app
/// unusable on macOS 26 with no way out except downgrading the whole app
/// (issue #34). The recursion that caused it is fixed, and glass was never the
/// cause — but the next glass regression may live in the system rather than
/// here, so users keep a door that does not require a new build from us.
///
/// Deliberately not a settings toggle: this is an escape hatch, not a look.
enum LiquidGlassPopupAvailability {
    static func usesLiquidGlass(
        systemSupportsLiquidGlass: Bool,
        forceLegacyPopover: Bool
    ) -> Bool {
        systemSupportsLiquidGlass && !forceLegacyPopover
    }

    /// `defaults write com.jamesli.usagedock tokenRemain.forceLegacyPopover.v1 -bool YES`
    static func forceLegacyPopover(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: PreferencesStore.forceLegacyPopoverKey)
    }
}
