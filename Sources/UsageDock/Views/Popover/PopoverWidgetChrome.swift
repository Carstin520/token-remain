import SwiftUI

struct PopoverWidgetHeader<Summary: View>: View {
    let widget: PopoverWidget
    let isExpanded: Bool
    let isPinned: Bool
    let onToggleExpanded: () -> Void
    let onTogglePinned: () -> Void
    let onHide: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    @ViewBuilder let summary: () -> Summary

    var body: some View {
        headerContent
        .help(L10n.text("widget.drag_help"))
        .contextMenu {
            if widget.supportsExpansion {
                Button(isPinned ? L10n.text("widget.stop_keep_expanded") : L10n.text("widget.keep_expanded"), action: onTogglePinned)
                Button(isExpanded ? L10n.text("widget.collapse") : L10n.text("widget.expand"), action: onToggleExpanded)
                Divider()
            }
            Button(L10n.text("widget.move_up"), action: onMoveUp)
            Button(L10n.text("widget.move_down"), action: onMoveDown)
            Divider()
            Button(role: .destructive, action: onHide) {
                Label(L10n.format("widget.remove_named", widget.title), systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(L10n.text("widget.drag_accessibility"))
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                titleLabel
                    .directReorderHandle()

                if widget.supportsExpansion {
                    compactButton(
                        systemImage: isExpanded ? "chevron.down" : "chevron.right",
                        help: isExpanded ? L10n.text("widget.collapse") : L10n.text("widget.expand"),
                        role: .muted,
                        action: onToggleExpanded
                    )
                }

                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .contentShape(Rectangle())
                    .directReorderHandle()
                summary()

                if widget.supportsExpansion {
                    compactButton(
                        systemImage: isPinned ? "pin.fill" : "pin",
                        help: isPinned ? L10n.text("widget.stop_keep_expanded") : L10n.text("widget.keep_expanded"),
                        role: isPinned ? .primary : .muted,
                        action: onTogglePinned
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 20, alignment: .top)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var widgetIcon: some View {
        if let provider = widget.provider {
            BrandIcon(provider: provider)
                .usageDockAdaptiveForeground(.primary)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: widget.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .usageDockAdaptiveForeground(.secondary)
                .frame(width: 20, height: 20)
        }
    }

    private var titleLabel: some View {
        HStack(spacing: 8) {
            // The local-usage SF Symbol was unavailable on some macOS builds,
            // leaving a blank 28pt slot before the title. Its donut chart is
            // already the card's visual identity, so the title starts at the
            // card's true leading edge instead of retaining a phantom indent.
            if widget != .localUsage {
                widgetIcon
            }
            Text(widget.title)
                .font(.system(size: 14, weight: .semibold))
                .usageDockAdaptiveForeground(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(alignment: .leading)
        .layoutPriority(1)
    }

    private func compactButton(
        systemImage: String,
        help: String,
        role: UsageDockForegroundRole,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .usageDockAdaptiveForeground(role)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
