import SwiftUI

/// Shared opt-in control on the account page and the all-accounts quota card.
struct CombinedAccountControl: View {
    let provider: ProviderQuota.Provider
    let snapshots: [ProviderAccountSnapshot]
    @ObservedObject var preferences: PreferencesStore = .shared
    var onEnable: () -> Void = {}
    @State private var pendingGroup: CombinedAccountQuota?

    private var requested: Bool { preferences.combinedAccountConsent[provider.rawValue] != nil }
    private var result: Result<CombinedAccountQuota, CombinedAccountQuota.Unavailable> {
        CombinedAccountQuota.evaluate(snapshots)
    }
    private var candidate: CombinedAccountQuota? { try? result.get() }

    var body: some View {
        if snapshots.filter({ !$0.profile.isSystem || $0.quota != nil }).count >= 2 || requested {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L10n.text("accounts.combined.toggle"), isOn: Binding(
                    get: { requested },
                    set: { enabled in
                        if enabled { pendingGroup = candidate }
                        else { preferences.setCombinedAccountConsent(nil, for: provider) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))
                .disabled(!requested && candidate == nil)
                if case .failure(let reason) = result {
                    Text(L10n.text(reason.localizationKey)).font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else if requested, let candidate, !preferences.combinesAccounts(for: provider, group: candidate) {
                    Text(L10n.text("accounts.combined.changed")).font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .alert(L10n.text("accounts.combined.confirm_title"), isPresented: Binding(
                get: { pendingGroup != nil }, set: { if !$0 { pendingGroup = nil } }
            ), presenting: pendingGroup) { group in
                Button(L10n.text("action.cancel"), role: .cancel) { pendingGroup = nil }
                Button(L10n.text("accounts.combined.confirm")) {
                    // Refresh/membership changes while the alert is open must
                    // not silently extend the user's confirmation to a new group.
                    if candidate?.consentFingerprint == group.consentFingerprint {
                        preferences.setCombinedAccountConsent(group.consentFingerprint, for: provider)
                        onEnable()
                    }
                    pendingGroup = nil
                }
            } message: { group in
                Text(L10n.format("accounts.combined.confirm_body", group.plan,
                    group.windows.first?.segments.map(\.name).joined(separator: ", ") ?? ""))
            }
        }
    }
}

struct CombinedAccountQuotaView: View {
    let group: CombinedAccountQuota
    let windows: [CombinedAccountQuota.Window]
    let provider: ProviderQuota.Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.format("accounts.combined.summary", group.accountCount, group.plan))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            windowTitle(window)
                            Spacer(minLength: 8)
                            amount(window)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            windowTitle(window)
                            amount(window)
                        }
                    }
                    // Equal-width account segments preserve attribution. A
                    // 150/200 total fills 75% overall, never a clamped 100% bar.
                    HStack(spacing: 8) {
                        ForEach(window.segments) { segment in
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(DashboardSurface.surface2)
                                    Capsule().fill(DashboardTheme.accent(for: provider))
                                        .frame(width: proxy.size.width * segment.remaining / 100)
                                }
                            }
                            .frame(height: 7)
                            .accessibilityLabel("\(segment.name): \(UsageFormatting.percent(segment.remaining))")
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(Array(window.segments.enumerated()), id: \.element.id) { index, segment in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(index + 1). \(segment.name)").font(.system(size: 10.5, weight: .medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(UsageFormatting.percent(segment.remaining))
                                    .numericFont(10.5, .semibold)
                                Text(segment.resetsAt.map {
                                    L10n.format("accounts.combined.reset", UsageFormatting.countdown(to: $0))
                                } ?? L10n.text("accounts.combined.reset_unknown"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(DashboardTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let next = window.nextReset {
                        Text(L10n.format("accounts.combined.next_reset",
                            UsageFormatting.countdown(to: next), UsageFormatting.percent(window.nextRestored)))
                            .font(.system(size: 10))
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(L10n.format("accounts.combined.updated", group.oldestReading.formatted(date: .omitted, time: .shortened)))
                .font(.system(size: 10)).foregroundStyle(DashboardTheme.mutedText)
        }
    }

    private func windowTitle(_ window: CombinedAccountQuota.Window) -> some View {
        Text(window.name ?? UsageFormatting.windowName(minutes: window.minutes))
            .font(.system(size: 11, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func amount(_ window: CombinedAccountQuota.Window) -> some View {
        Text(L10n.format("accounts.combined.remaining", UsageFormatting.percent(window.remaining),
                        UsageFormatting.percent(window.capacity)))
            .numericFont(12, .semibold)
            .fixedSize(horizontal: false, vertical: true)
    }
}
