import SwiftUI
import UniformTypeIdentifiers

struct PopoverWidgetHeader<Summary: View>: View {
    let widget: PopoverWidget
    let isExpanded: Bool
    let isPinned: Bool
    @Binding var draggingWidget: PopoverWidget?
    /// A complete, non-interactive rendering of the widget. Keeping this
    /// separate from the header makes the full card follow the pointer while
    /// the header remains the only drag handle.
    let dragPreview: (() -> AnyView)?
    let onToggleExpanded: () -> Void
    let onTogglePinned: () -> Void
    let onHide: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    @ViewBuilder let summary: () -> Summary

    var body: some View {
        Group {
            if let dragPreview {
                headerContent
                    .onDrag {
                        draggingWidget = widget
                        return NSItemProvider(object: widget.rawValue as NSString)
                    } preview: {
                        dragPreview()
                    }
            } else {
                headerContent
            }
        }
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
                if widget.supportsExpansion {
                    Button(action: onToggleExpanded) {
                        titleLabel
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    titleLabel
                }

                Spacer(minLength: 4)
                summary()

                if widget.supportsExpansion {
                    compactButton(
                        systemImage: isPinned ? "pin.fill" : "pin",
                        help: isPinned ? L10n.text("widget.stop_keep_expanded") : L10n.text("widget.keep_expanded"),
                        tint: isPinned ? DashboardTheme.text : DashboardTheme.mutedText,
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
                .foregroundStyle(DashboardTheme.text)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: widget.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DashboardTheme.secondaryText)
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
                .foregroundStyle(DashboardTheme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
            if widget.supportsExpansion {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DashboardTheme.mutedText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private func compactButton(
        systemImage: String,
        help: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PopoverWidgetDropDelegate: DropDelegate {
    let destination: PopoverWidget
    let layout: PopoverLayoutStore
    @Binding var draggingWidget: PopoverWidget?

    func dropEntered(info: DropInfo) {
        guard let draggingWidget, draggingWidget != destination else { return }
        withAnimation(.snappy(duration: 0.2)) {
            layout.move(draggingWidget, to: destination)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingWidget = nil
        return true
    }
}
