import SwiftUI

/// Compact, clickable provider-health indicator shown once beside the provider
/// name. Detailed status context stays available without repeating the badge on
/// every quota window.
struct ServiceStatusBadge: View {
    let status: ProviderServiceStatus
    @State private var isShowingDetails = false

    private var title: String {
        switch status.level {
        case .operational: L10n.text("service_status.operational")
        case .degradedPerformance: L10n.text("service_status.degraded")
        case .partialOutage: L10n.text("service_status.partial_outage")
        case .majorOutage: L10n.text("service_status.major_outage")
        case .maintenance: L10n.text("service_status.maintenance")
        case .unknown: L10n.text("service_status.unknown")
        }
    }

    private var tint: Color {
        switch status.level {
        case .operational: DashboardTheme.success
        case .degradedPerformance, .maintenance: DashboardTheme.warning
        case .partialOutage, .majorOutage: DashboardTheme.danger
        case .unknown: DashboardTheme.mutedText
        }
    }

    private var explanation: String {
        L10n.text(status.level.explanationLocalizationKey)
    }

    private var badgeLabel: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tint.opacity(0.11), in: Capsule())
        .contentShape(Capsule())
        .fixedSize()
    }

    private var helpText: String {
        "\(title)：\(explanation)"
    }

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            badgeLabel
        }
        .buttonStyle(.plain)
        .help(helpText)
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            ServiceStatusDetails(status: status, title: title, tint: tint)
        }
        .accessibilityLabel("\(status.provider.displayName) \(title)")
        .accessibilityHint(explanation)
    }
}

private struct ServiceStatusDetails: View {
    let status: ProviderServiceStatus
    let title: String
    let tint: Color

    private var explanation: String {
        L10n.text(status.level.explanationLocalizationKey)
    }

    private var componentText: String? {
        let names = status.affectedComponentNames.isEmpty
            ? status.componentNames
            : status.affectedComponentNames
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text("\(status.provider.displayName) · \(title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
            }

            Text(explanation)
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let componentText {
                Label(componentText, systemImage: "square.stack.3d.up")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .overlay(DashboardTheme.border)

            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Label(
                        UsageFormatting.freshnessDescription(
                            since: status.checkedAt,
                            now: context.date
                        ),
                        systemImage: "clock"
                    )
                }
                .font(.system(size: 10))
                .foregroundStyle(DashboardTheme.mutedText)

                Spacer(minLength: 6)

                Link(destination: status.statusPageURL) {
                    Label(
                        status.statusPageURL.host ?? status.statusPageURL.absoluteString,
                        systemImage: "arrow.up.right.square"
                    )
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DashboardTheme.secondaryText)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}
