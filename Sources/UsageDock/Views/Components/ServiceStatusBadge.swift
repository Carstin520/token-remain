import SwiftUI

/// Compact provider-health indicator used beside quota-window names and, only
/// during an incident, beside the provider name in the menu-bar popover.
struct ServiceStatusBadge: View {
    let status: ProviderServiceStatus

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

    private var helpText: String {
        let names = status.affectedComponentNames.isEmpty
            ? status.componentNames
            : status.affectedComponentNames
        let componentText = names.isEmpty ? status.provider.displayName : names.joined(separator: ", ")
        return "\(componentText) · \(title)\n\(status.statusPageURL.absoluteString)"
    }

    var body: some View {
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
        .fixedSize()
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
