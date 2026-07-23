import AppIntents
import SwiftUI
import TokenRemainKit
import WidgetKit

private extension View {
    /// Every widget uses the ink canvas; Lock Screen families ignore it and take
    /// the system's vibrant monochrome rendering, which is exactly the design.
    func trWidgetContainer() -> some View {
        containerBackground(TRTheme.ink, for: .widget)
    }
}

struct TRHeroWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRHeroWidget", provider: TRTimelineProvider()) { entry in
            TRHeroView(entry: entry)
                .widgetURL(TRRoute.overview.url)
                .trWidgetContainer()
        }
        .configurationDisplayName("TokenRemain")
        .description(TRL10n.t("widget.desc.min"))
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct TRProvidersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRProvidersWidget", provider: TRTimelineProvider()) { entry in
            TRProvidersView(entry: entry)
                .widgetURL(TRRoute.limits.url)
                .trWidgetContainer()
        }
        .configurationDisplayName(TRL10n.t("widget.name.quota"))
        .description(TRL10n.t("widget.desc.quota"))
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct TRInlineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRInlineWidget", provider: TRTimelineProvider()) { entry in
            TRInlineView(entry: entry)
                .widgetURL(TRRoute.overview.url)
                .trWidgetContainer()
        }
        .configurationDisplayName("TokenRemain")
        .description(TRL10n.t("widget.desc.min"))
        .supportedFamilies([.accessoryInline])
    }
}

struct TRCircularWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRCircularWidget", provider: TRTimelineProvider()) { entry in
            TRCircularView(entry: entry)
                .widgetURL(TRRoute.overview.url)
                .trWidgetContainer()
        }
        .configurationDisplayName(TRL10n.t("widget.name.percent"))
        .description(TRL10n.t("widget.desc.min"))
        .supportedFamilies([.accessoryCircular])
    }
}

struct TRResetCircularWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRResetCircularWidget", provider: TRTimelineProvider()) { entry in
            TRResetCircularView(entry: entry)
                .widgetURL(TRRoute.limits.url)
                .trWidgetContainer()
        }
        .configurationDisplayName(TRL10n.t("widget.name.reset"))
        .description(TRL10n.t("widget.desc.reset"))
        .supportedFamilies([.accessoryCircular])
    }
}

struct TRRectangularWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRRectangularWidget", provider: TRTimelineProvider()) { entry in
            TRRectangularView(entry: entry)
                .widgetURL(TRRoute.overview.url)
                .trWidgetContainer()
        }
        .configurationDisplayName("TokenRemain")
        .description(TRL10n.t("widget.desc.min"))
        .supportedFamilies([.accessoryRectangular])
    }
}

/// Action Button / Control Center / Lock Screen control. Runs the same
/// `RefreshSnapshotIntent` the shortcut does.
struct TRRefreshControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TRRefreshControl") {
            ControlWidgetButton(action: RefreshSnapshotIntent()) {
                Label(TRL10n.t("intent.refresh.title"), systemImage: "arrow.clockwise")
            }
        }
        // ControlWidget metadata is extracted at build time, so these stay literals.
        .displayName("TokenRemain")
        .description("Refresh quota")
    }
}

@main
struct TokenRemainWidgetBundle: WidgetBundle {
    var body: some Widget {
        TRHeroWidget()
        TRProvidersWidget()
        TRInlineWidget()
        TRCircularWidget()
        TRResetCircularWidget()
        TRRectangularWidget()
        TRRefreshControl()
        TokenRemainLiveActivity()
    }
}

#Preview("Small · concept", as: .systemSmall) {
    TRHeroWidget()
} timeline: {
    TREntry.placeholder(now: SnapshotComposer.previewNow)
    TREntry.empty(now: SnapshotComposer.previewNow)
}

#Preview("Medium · concept", as: .systemMedium) {
    TRProvidersWidget()
} timeline: {
    TREntry.placeholder(now: SnapshotComposer.previewNow)
    TREntry.empty(now: SnapshotComposer.previewNow)
}
