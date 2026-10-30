import SwiftUI

/// Dashboard Limits: the authoritative view of every official quota window,
/// reusing the popover's `QuotaCard`. Pure live data. Providers that are not
/// connected yet render their onboarding hint inside the card instead of an
/// endless spinner. Providers that require a pasted API key or cookie expose
/// that setup directly in the empty quota card.
struct LimitsSection: View {
    private static let reorderCoordinateSpace = "tokenremain.dashboard.limits.direct-reorder"
    static let columnMinimum: CGFloat = 300
    static let columnMaximum: CGFloat = 460
    static let columnSpacing: CGFloat = 14

    let insights: UsageInsights
    var notices: [ProviderQuota.Provider: String] = [:]
    var serviceStatuses: [ProviderQuota.Provider: ProviderServiceStatus] = [:]
    @ObservedObject var store: UsageStore
    @ObservedObject var tracked: TrackedProvidersStore = .shared
    let reorderInteraction: DirectReorderInteraction<ProviderQuota.Provider>

    /// Multi-account providers read the store's selection-aware projection;
    /// single-account providers keep using the original insights snapshot.
    private func quota(for provider: ProviderQuota.Provider) -> ProviderQuota? {
        guard provider.multiAccountCapability != nil else { return insights.quota(for: provider) }
        return store.displayedQuota(for: provider)
    }

    private func notice(for provider: ProviderQuota.Provider) -> String? {
        guard provider.multiAccountCapability != nil else { return notices[provider] }
        return store.displayedNotice(for: provider) ?? notices[provider]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.limits.title,
                subtitle: DashboardSection.limits.subtitle,
                trailing: insights.lastUpdated.map { L10n.format("common.updated_at", $0.formatted(date: .omitted, time: .standard)) }
            )

            QuotaGridLayout(
                minimumColumnWidth: Self.columnMinimum,
                maximumColumnWidth: Self.columnMaximum,
                spacing: Self.columnSpacing
            ) {
                ForEach(tracked.enabledOrdered, id: \.self) { provider in
                    QuotaCard(
                        provider: provider,
                        quota: quota(for: provider),
                        serviceStatus: serviceStatuses[provider],
                        notice: notice(for: provider),
                        store: store
                    )
                        .frame(maxWidth: .infinity, alignment: .top)
                        .directReorder(
                            item: provider,
                            candidates: tracked.enabledOrdered,
                            coordinateSpace: Self.reorderCoordinateSpace,
                            interaction: reorderInteraction,
                            layout: .grid(spacing: 14),
                            move: { source, target in
                                tracked.move(source, to: target)
                            }
                        )
                        .help(L10n.text("quota.drag_help"))
                        .accessibilityHint(L10n.text("quota.drag_accessibility"))
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation(.snappy) { tracked.setEnabled(provider, false) }
                            } label: {
                                Label(L10n.format("limits.stop_tracking_named", provider.displayName), systemImage: "minus.circle")
                            }
                        }
                        // Apply the stacking trait after help/context-menu
                        // wrappers so the lifted card is the grid's top sibling
                        // and visibly covers every card it crosses.
                        .zIndex(reorderInteraction.isDragging(provider) ? 10_000 : 0)
                }

                if !tracked.disabledOrdered.isEmpty {
                    AddProviderTile(tracked: tracked)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(title: L10n.text("limits.about_windows_title"))
                    Text(L10n.text("limits.about_windows_body"))
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("limits.manage_tracking_hint"))
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("limits.reset_time_note"))
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .coordinateSpace(name: Self.reorderCoordinateSpace)
    }
}

/// Adaptive quota grid whose rows read as even bands: every cell in a row is
/// offered the row's tallest natural height. Columns and row heights come out
/// of one layout pass, so nothing is measured into state and written back.
/// 1.4.7 (46) did that with `LazyVGrid` plus measured `@State` heights, and
/// the measure → state → relayout cycle never settled on some dashboards:
/// the main thread spun at 100% CPU and memory grew by gigabytes.
struct QuotaGridLayout: Layout {
    var minimumColumnWidth: CGFloat
    var maximumColumnWidth: CGFloat
    var spacing: CGFloat

    /// `GridItem.adaptive` fits as many minimum-width columns as the width allows.
    static func columnCount(forWidth width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int((width + spacing) / (minimum + spacing)))
    }

    /// Columns share the width evenly up to the maximum and pack leading.
    static func columnWidth(forWidth width: CGFloat, columns: Int, maximum: CGFloat, spacing: CGFloat) -> CGFloat {
        let columns = max(1, columns)
        let shared = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return max(0, min(maximum, shared))
    }

    /// Each row is as tall as its tallest cell, so rows stay only as tall as
    /// their own content.
    static func rowHeights(natural: [CGFloat], columns: Int) -> [CGFloat] {
        let columns = max(1, columns)
        return stride(from: 0, to: natural.count, by: columns).map { start in
            natural[start..<min(start + columns, natural.count)].max() ?? 0
        }
    }

    private struct Grid {
        var columns: Int
        var columnWidth: CGFloat
        var rowHeights: [CGFloat]
    }

    private func grid(for proposal: ProposedViewSize, subviews: Subviews) -> Grid {
        // A missing or unbounded width has no column count to fit; fall back
        // to one minimum-width column instead of an unbounded one.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumColumnWidth
        let columns = Self.columnCount(forWidth: width, minimum: minimumColumnWidth, spacing: spacing)
        let columnWidth = Self.columnWidth(
            forWidth: width,
            columns: columns,
            maximum: maximumColumnWidth,
            spacing: spacing
        )
        let natural = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }
        return Grid(
            columns: columns,
            columnWidth: columnWidth,
            rowHeights: Self.rowHeights(natural: natural, columns: columns)
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = grid(for: proposal, subviews: subviews)
        let usedColumns = min(grid.columns, max(1, subviews.count))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? grid.columnWidth * CGFloat(usedColumns) + spacing * CGFloat(usedColumns - 1)
        let height = grid.rowHeights.reduce(0, +) + spacing * CGFloat(max(0, grid.rowHeights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = grid(for: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        var y = bounds.minY
        for (row, rowHeight) in grid.rowHeights.enumerated() {
            let start = row * grid.columns
            for index in start..<min(start + grid.columns, subviews.count) {
                let column = CGFloat(index - start)
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + column * (grid.columnWidth + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: grid.columnWidth, height: rowHeight)
                )
            }
            y += rowHeight + spacing
        }
    }
}

/// 「添加应用」虚线卡片:列出未追踪的应用与它们的检测状态,
/// 点一下即加入追踪(与卡片右键"停止追踪"互为镜像)。
private struct AddProviderTile: View {
    @ObservedObject var tracked: TrackedProvidersStore
    /// Detection probes the file system and reads the app's own Keychain
    /// items. It runs when the tile appears or the tracked set changes, off
    /// the main thread, not on every UsageStore update that re-renders Limits.
    @State private var allDetections: [TrackedProvidersStore.Detection] = []

    private var detections: [TrackedProvidersStore.Detection] {
        allDetections.filter { !tracked.isEnabled($0.provider) }
    }

    var body: some View {
        Menu {
            ForEach(detections) { detection in
                Button {
                    withAnimation(.snappy) { tracked.setEnabled(detection.provider, true) }
                } label: {
                    Label(
                        detection.installed
                            ? L10n.format("limits.provider_detected", detection.provider.displayName)
                            : L10n.format("limits.provider_not_detected", detection.provider.displayName),
                        systemImage: detection.installed ? "checkmark.circle" : "circle.dashed"
                    )
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.dashed")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(DashboardTheme.secondaryText)
                Text(L10n.text("limits.add_app"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Text(L10n.text("limits.add_app_subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 132)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        DashboardSurface.border,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(L10n.text("limits.add_app_accessibility"))
        .task(id: tracked.enabled) {
            let detections = await Task.detached(priority: .utility) {
                TrackedProvidersStore.detections()
            }.value
            guard !Task.isCancelled else { return }
            allDetections = detections
        }
    }
}
