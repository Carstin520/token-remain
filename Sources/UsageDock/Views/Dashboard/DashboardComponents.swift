import SwiftUI

/// Large header for a Dashboard detail pane: title, subtitle and an optional
/// trailing meta string (typically the last-updated time).
struct SectionTitleHeader: View {
    let title: String
    let subtitle: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(DashboardTheme.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            Spacer(minLength: 12)
            if let trailing {
                Text(trailing)
                    .numericFont(12)
                    .foregroundStyle(DashboardTheme.mutedText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Shared geometry for the four primary Overview modules. Their headers stay
/// pinned to the same top inset while variable content scrolls inside a fixed
/// card, keeping the 2x2 grid aligned even when live data changes shape.
enum DashboardOverviewLayout {
    static let gridSpacing: CGFloat = 14
    static let panelContentHeight: CGFloat = 196
}

struct OverviewPanelCard<Header: View, Content: View>: View {
    private let contentSpacing: CGFloat
    private let scrollsContent: Bool
    private let header: Header
    private let content: Content

    init(
        contentSpacing: CGFloat = 12,
        scrollsContent: Bool = true,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.contentSpacing = contentSpacing
        self.scrollsContent = scrollsContent
        self.header = header()
        self.content = content()
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                contentArea
            }
            .frame(
                height: DashboardOverviewLayout.panelContentHeight,
                alignment: .top
            )
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var contentArea: some View {
        if scrollsContent {
            ScrollView(.vertical) {
                contentStack
            }
            .scrollIndicators(.automatic)
        } else {
            contentStack
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Honest empty state used where UsageDock does not yet have the data a section
/// would show (e.g. multi-day history). Never a substitute for real data.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(DashboardTheme.secondaryText)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DashboardTheme.text)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(DashboardTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .accessibilityElement(children: .combine)
    }
}

/// A bulleted list of planned capabilities, clearly labeled as direction rather
/// than shipped features.
struct RoadmapList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(DashboardTheme.purple)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    Text(item)
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label/value row for the settings and data-source panels.
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = DashboardTheme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DashboardTheme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(value)
                .numericFont(12, .medium)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small status dot + label used for source / sync health.
struct StatusDotLabel: View {
    let color: Color
    let text: String
    var bold: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: bold ? .semibold : .regular))
                .foregroundStyle(DashboardTheme.text)
        }
    }
}
