import SwiftUI

/// Dashboard Data Sources: live status of each local source UsageDock reads,
/// automatic local-app discovery plus explicit credential setup where required,
/// any current error surfaced verbatim, and the privacy posture. All real.
struct DataSourcesSection: View {
    @ObservedObject var store: UsageStore
    let insights: UsageInsights
    @ObservedObject var feedStore: AIFeedStore
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.dataSources.title,
                subtitle: DashboardSection.dataSources.subtitle
            )

            DashboardCard {
                VStack(alignment: .leading, spacing: 0) {
                    PanelHeader(title: L10n.text("datasource.status_title"))
                        .padding(.bottom, 4)
                    Text(L10n.text("datasource.visibility_note"))
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                    if visibleSources.isEmpty {
                        Text(L10n.text("datasource.none_connected"))
                            .font(.system(size: 12))
                            .foregroundStyle(DashboardTheme.mutedText)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
                    } else {
                        ForEach(visibleSources, id: \.self) { source in
                            if source != visibleSources.first {
                                rowDivider
                            }
                            sourceRow(source)
                        }
                    }
                }
            }

            if let errorMessage {
                DashboardCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.text("datasource.diagnostics_title"), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DashboardTheme.warning)
                        Text(errorMessage)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(title: L10n.text("privacy.title"))
                    RoadmapList(items: [
                        L10n.text("privacy.local_only"),
                        L10n.text("privacy.readonly_credentials"),
                        L10n.text("privacy.zai_key"),
                        L10n.text("privacy.cost_estimate"),
                        L10n.text("privacy.feed_managed")
                    ])
                }
            }
        }
    }

    private enum VisibleSource: Hashable {
        case provider(ProviderQuota.Provider)
        case ccusage
        case feed
    }

    /// Provider 保留持久化的成功连接历史，同时让当前追踪的手动凭据型
    /// 来源在首次连接前就显示输入框；ccusage 是安装包内置来源，首次读取
    /// 结束后即展示，即使结果为空或失败也能被用户诊断。
    private var visibleSources: [VisibleSource] {
        var sources = store.dataSourceProviders.map(VisibleSource.provider)
        if store.localUsageStatus != .loading || insights.daily != nil {
            sources.append(.ccusage)
        }
        if feedStore.lastUpdated != nil { sources.append(.feed) }
        return sources
    }

    @ViewBuilder
    private func sourceRow(_ source: VisibleSource) -> some View {
        switch source {
        case .provider(let provider):
            let quota = insights.quota(for: provider)
            SourceHealthRow(
                name: sourceName(for: provider),
                detail: store.providerNotices[provider] ?? sourceDetail(for: provider),
                healthy: quota != nil && store.providerNotices[provider] == nil,
                capturedAt: quota?.capturedAt
            )
            providerCredentialRow(for: provider)
        case .ccusage:
            SourceHealthRow(
                name: "ccusage",
                detail: ccusageDetail,
                healthy: ccusageHealthy,
                capturedAt: insights.daily?.capturedAt ?? insights.history?.capturedAt
            )
        case .feed:
            SourceHealthRow(
                name: L10n.text("datasource.feed_name"),
                detail: feedSourceDetail,
                healthy: true,
                capturedAt: feedStore.lastUpdated
            )
        }
    }

    private var ccusageDetail: String {
        if case .failed(let message) = store.localUsageStatus {
            return message
        }
        switch store.ccusageUpdateStatus {
        case .checking(let installedVersion):
            return L10n.format("datasource.ccusage_checking", installedVersion)
        case .current(let installedVersion, _):
            return L10n.format("datasource.ccusage_current", installedVersion)
        case .updateAvailable(let installedVersion, let latestVersion, _):
            return L10n.format(
                "datasource.ccusage_update_available",
                installedVersion,
                latestVersion
            )
        case .checkFailed(let installedVersion):
            return L10n.format("datasource.ccusage_check_failed", installedVersion)
        }
    }

    private var ccusageHealthy: Bool {
        guard !store.ccusageUpdateStatus.needsUpdate else { return false }
        switch store.localUsageStatus {
        case .available, .empty: return true
        case .loading, .failed: return false
        }
    }

    @ViewBuilder
    private func providerCredentialRow(for provider: ProviderQuota.Provider) -> some View {
        switch provider {
        case .openrouter:
            APIKeyRow(
                store: store,
                provider: provider,
                placeholder: L10n.text("datasource.openrouter_key_placeholder"),
                hasStoredKey: OpenRouterKeyStore().hasStoredKey()
            )
        case .zai:
            APIKeyRow(
                store: store,
                provider: provider,
                placeholder: L10n.text("datasource.zai_key_placeholder"),
                hasStoredKey: ZAIKeyStore().hasStoredKey()
            )
        default:
            if let descriptor = ProviderSecretStore.descriptor(for: provider) {
                APIKeyRow(
                    store: store,
                    provider: provider,
                    placeholder: descriptor.placeholder,
                    hasStoredKey: ProviderSecretStore(provider: provider).hasStoredSecret()
                )
            }
        }
    }

    private func sourceName(for provider: ProviderQuota.Provider) -> String {
        switch provider {
        case .claude: return "Claude Code"
        case .grok: return L10n.text("datasource.name_grok")
        case .zai: return L10n.text("datasource.name_zai")
        default: return provider.displayName
        }
    }

    private func sourceDetail(for provider: ProviderQuota.Provider) -> String {
        switch provider {
        case .claude: return L10n.text("datasource.detail.claude")
        case .codex: return L10n.text("datasource.detail.codex")
        case .cursor: return L10n.text("datasource.detail.cursor")
        case .copilot: return L10n.text("datasource.detail.copilot")
        case .devin: return L10n.text("datasource.detail.devin")
        case .grok: return L10n.text("datasource.detail.grok")
        case .openrouter: return L10n.text("datasource.detail.openrouter")
        case .antigravity: return L10n.text("datasource.detail.antigravity")
        case .opencode: return L10n.text("datasource.detail.opencode")
        case .zai: return L10n.text("datasource.detail.zai")
        case .kiro: return L10n.text("datasource.detail.kiro")
        case .ollama: return L10n.text("datasource.detail.ollama")
        default: return L10n.text("datasource.detail.default")
        }
    }

    private var rowDivider: some View {
        Divider().overlay(DashboardTheme.border).padding(.vertical, 12)
    }

    private var feedSourceDetail: String {
        feedStore.lastUpdated == nil
            ? L10n.text("datasource.feed_waiting")
            : L10n.text("datasource.feed_active")
    }
}

/// 需要 API Key / Cookie 的 provider 的一次性接入入口:
/// 粘贴 → 存钥匙串 → 立即直查。已接入时显示替换/清除;Key 永不回显。
private struct APIKeyRow: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderQuota.Provider
    let placeholder: String
    @State var hasStoredKey: Bool
    @State private var draftKey = ""
    @State private var isSaving = false

    private func storedKeyExists() -> Bool {
        switch provider {
        case .zai: return ZAIKeyStore().hasStoredKey()
        case .openrouter: return OpenRouterKeyStore().hasStoredKey()
        default: return ProviderSecretStore(provider: provider).hasStoredSecret()
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            SecureField(hasStoredKey ? L10n.text("datasource.key_saved_placeholder") : placeholder, text: $draftKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .disabled(isSaving)

            Button(hasStoredKey ? L10n.text("action.replace") : L10n.text("action.save")) {
                let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return }
                isSaving = true
                Task {
                    await store.saveAPIKey(key, for: provider)
                    draftKey = ""
                    hasStoredKey = storedKeyExists()
                    isSaving = false
                }
            }
            .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

            if hasStoredKey {
                Button(L10n.text("action.clear")) {
                    isSaving = true
                    Task {
                        await store.clearAPIKey(for: provider)
                        hasStoredKey = storedKeyExists()
                        isSaving = false
                    }
                }
                .disabled(isSaving)
            }
        }
        .controlSize(.small)
        .padding(.top, 8)
        .padding(.leading, 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("datasource.api_key_settings", provider.displayName))
    }
}

private struct SourceHealthRow: View {
    let name: String
    let detail: String
    let healthy: Bool
    let capturedAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(healthy ? DashboardTheme.success : DashboardTheme.warning)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(healthy ? L10n.text("datasource.healthy") : L10n.text("datasource.broken"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(healthy ? DashboardTheme.success : DashboardTheme.warning)
                if let capturedAt {
                    Text(capturedAt.formatted(date: .omitted, time: .shortened))
                        .numericFont(10)
                        .foregroundStyle(DashboardTheme.mutedText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
