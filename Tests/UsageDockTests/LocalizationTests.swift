import Foundation
import Testing
@testable import UsageDock

@Suite("Localization")
struct LocalizationTests {
    private let locales = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de",
        "pt-BR", "it", "ru", "ar", "hi", "tr", "vi", "id"
    ]

    private let requiredKeys = [
        "widget.local_usage",
        "widget.ai_feed",
        "nav.overview",
        "nav.limits",
        "nav.trends",
        "nav.devices",
        "nav.data_sources",
        "nav.settings",
        "section.overview.subtitle",
        "risk.headline.low",
        "risk.headline.projected_runout",
        "risk.summary.projected_runout",
        "duration.days_hours_minutes",
        "duration.hours_minutes",
        "reset.countdown",
        "freshness.minutes",
        "quota.remaining",
        "pace.projected_in",
        "widget.all_visible",
        "widget.add_named",
        "widget.keep_expanded",
        "widget.stop_keep_expanded",
        "widget.collapse",
        "widget.expand",
        "widget.move_up",
        "widget.move_down",
        "widget.remove_named",
        "widget.drag_help",
        "widget.drag_accessibility",
        "action.add_widget",
        "action.refresh_quota",
        "action.refresh_usage",
        "action.open_dashboard",
        "action.open_dashboard_help",
        "action.launch_at_login",
        "action.open_dashboard_settings",
        "action.restart_app",
        "action.settings",
        "action.quit",
        "action.quit_app",
        "usage.updated_local",
        "usage.loading_local",
        "usage.provider_breakdown_empty",
        "usage.loading_ccusage",
        "usage.provider_help",
        "usage.provider_accessibility",
        "usage.spend_today",
        "usage.spend_yesterday",
        "usage.spend_last30",
        "usage.trend",
        "quota.loading_official",
        "feed.updating",
        "feed.item_count",
        "feed.filtering",
        "feed.full_top_stories",
        "feed.important_updates",
        "feed.view_all",
        "feed.open_x_hint"
    ]

    @Test("Every supported locale contains the product-critical UI keys")
    func everyLocaleContainsCoreKeys() throws {
        for locale in locales {
            let strings = try loadStrings(locale: locale)
            for key in requiredKeys {
                let value = strings[key]
                #expect(value != nil, "Missing \(key) in \(locale)")
                #expect(value?.isEmpty == false, "Empty \(key) in \(locale)")
                #expect(value != key, "Untranslated \(key) in \(locale)")
            }
        }
    }

    /// Locales the product promises complete coverage for. Every key in the
    /// English catalog must exist there — new UI strings cannot ship
    /// English-only (or Chinese-only) in these languages.
    private let fullyLocalizedLocales = ["zh-Hans", "zh-Hant", "es", "de", "ja", "ko"]

    @Test("Fully localized locales cover the entire English catalog")
    func fullyLocalizedLocalesCoverAllKeys() throws {
        let english = try loadStrings(locale: "en")
        for locale in fullyLocalizedLocales {
            let strings = try loadStrings(locale: locale)
            let missing = Set(english.keys).subtracting(strings.keys)
            #expect(
                missing.isEmpty,
                "\(locale) is missing \(missing.count) keys, e.g. \(missing.sorted().prefix(8))"
            )
            for (key, value) in strings {
                #expect(!value.isEmpty, "Empty \(key) in \(locale)")
            }
            for key in english.keys {
                #expect(
                    placeholders(in: strings[key] ?? "").sorted()
                        == placeholders(in: english[key] ?? "").sorted(),
                    "Placeholder mismatch for \(key) in \(locale)"
                )
            }
        }
    }

    @Test("Arabic ships a real RTL localization")
    func arabicIsNotAnEnglishFallback() throws {
        let strings = try loadStrings(locale: "ar")
        #expect(strings["widget.local_usage"] == "الاستخدام المحلي اليوم")
        #expect(strings["nav.settings"] == "الإعدادات")
        #expect(strings["action.open_dashboard"] == "فتح لوحة المعلومات")
    }

    @Test("Format placeholders stay compatible in every locale")
    func formatPlaceholdersMatchEnglish() throws {
        let english = try loadStrings(locale: "en")
        for locale in locales where locale != "en" {
            let strings = try loadStrings(locale: locale)
            for key in requiredKeys {
                #expect(
                    placeholders(in: strings[key] ?? "").sorted()
                        == placeholders(in: english[key] ?? "").sorted(),
                    "Placeholder mismatch for \(key) in \(locale)"
                )
            }
        }
    }

    @Test("USD values use the requested locale")
    func currencyUsesLocale() {
        let english = L10n.usd(188.99, locale: Locale(identifier: "en_US"))
        let german = L10n.usd(188.99, locale: Locale(identifier: "de_DE"))
        #expect(english.contains("188.99"))
        #expect(german.contains("188,99"))
    }

    private func loadStrings(locale: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Sources/UsageDock/Localization")
            .appendingPathComponent("\(locale).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: String])
    }

    private func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:\.\d+)?(?:@|lld|d|f)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }
}
