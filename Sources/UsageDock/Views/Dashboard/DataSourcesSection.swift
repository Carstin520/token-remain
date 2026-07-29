import SwiftUI
import UniformTypeIdentifiers

/// Dashboard Data Sources: live status of each local source UsageDock reads,
/// automatic local-app discovery plus explicit credential setup where required,
/// any current error surfaced verbatim, and the privacy posture. All real.
struct DataSourcesSection: View {
    @ObservedObject var store: UsageStore
    let insights: UsageInsights
    @ObservedObject var feedStore: AIFeedStore
    let errorMessage: String?
    @State private var isChoosingTraeDirectory = false

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
            .fileImporter(
                isPresented: $isChoosingTraeDirectory,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    store.addTraeAgentDirectory(url)
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
        case localAgent(String)
        case traeConfiguration
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
        sources.append(contentsOf: store.localUsageSourceIDs.map(VisibleSource.localAgent))
        sources.append(.traeConfiguration)
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
                detail: L10n.text("datasource.ccusage_detail"),
                healthy: ccusageHealthy,
                capturedAt: insights.daily?.capturedAt ?? insights.history?.capturedAt
            )
        case .localAgent(let id):
            LocalUsageSourceRow(
                id: id,
                enabled: Binding(
                    get: { store.isLocalUsageSourceEnabled(id) },
                    set: { store.setLocalUsageSourceEnabled($0, id: id) }
                ),
                capturedAt: localCapturedAt(for: id)
            )
        case .traeConfiguration:
            TraeAgentDirectoryRow(
                directories: store.traeAgentDirectories,
                removableDirectories: Set(store.configuredTraeAgentDirectories.map(\.path)),
                onChoose: { isChoosingTraeDirectory = true },
                onRemove: store.removeTraeAgentDirectory
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

    private func localCapturedAt(for id: String) -> Date? {
        let canonical = LocalUsageSourceCatalog.canonicalID(id)
        let hasDaily = insights.daily?.agents.contains {
            LocalUsageSourceCatalog.canonicalID($0.id) == canonical
        } == true
        let hasHistory = insights.history?.days.contains { day in
            day.agents.contains { LocalUsageSourceCatalog.canonicalID($0.id) == canonical }
        } == true
        return hasDaily || hasHistory
            ? insights.daily?.capturedAt ?? insights.history?.capturedAt
            : nil
    }

    private var ccusageHealthy: Bool {
        switch store.localUsageStatus {
        case .available, .empty: return true
        case .loading, .failed: return false
        }
    }

    @ViewBuilder
    private func providerCredentialRow(for provider: ProviderQuota.Provider) -> some View {
        switch provider {
        case .claude, .codex:
            ProviderAuthorizationRow(store: store, provider: provider)
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
        case .windsurf: return L10n.text("datasource.detail.windsurf")
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

/// Claude/Codex 的凭证归官方客户端所有。这里只提供两种显式操作：
/// 允许 TokenRemain 发起一次只读钥匙串读取，或打开官方应用完成登录/续期。
private struct ProviderAuthorizationRow: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderQuota.Provider
    @State private var isAuthorizing = false

    private var appName: String {
        switch provider {
        case .claude: "Claude"
        case .codex: "ChatGPT / Codex"
        default: provider.displayName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(
                    isAuthorizing
                        ? L10n.text("datasource.authorizing")
                        : L10n.text("datasource.authorize_read")
                ) {
                    isAuthorizing = true
                    Task {
                        _ = await store.authorizeProviderCredentials(provider)
                        isAuthorizing = false
                    }
                }
                .disabled(isAuthorizing)

                if ProviderDesktopAppService.applicationURL(for: provider) != nil {
                    Button(L10n.format("datasource.open_provider_app", appName)) {
                        ProviderDesktopAppService.open(provider)
                    }
                    .disabled(isAuthorizing)
                }
            }
            .controlSize(.small)

            Text(L10n.text("datasource.authorization_note"))
                .font(.system(size: 10))
                .foregroundStyle(DashboardTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .padding(.leading, 20)
    }
}

private struct LocalUsageSourceRow: View {
    let id: String
    @Binding var enabled: Bool
    let capturedAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(enabled ? DashboardTheme.success : DashboardTheme.mutedText)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalUsageSourceCatalog.displayName(for: id))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Text(L10n.text("datasource.local_agent_detail"))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(
                        L10n.format(
                            "datasource.local_agent_toggle",
                            LocalUsageSourceCatalog.displayName(for: id)
                        )
                    )
                if let capturedAt {
                    Text(capturedAt.formatted(date: .omitted, time: .shortened))
                        .numericFont(10)
                        .foregroundStyle(DashboardTheme.mutedText)
                }
            }
        }
    }
}

private struct TraeAgentDirectoryRow: View {
    let directories: [URL]
    let removableDirectories: Set<String>
    let onChoose: () -> Void
    let onRemove: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .frame(width: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("datasource.trae_agent_title"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DashboardTheme.text)
                    Text(L10n.text("datasource.trae_agent_detail"))
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(L10n.text("datasource.choose_folder"), action: onChoose)
                    .controlSize(.small)
            }
            ForEach(directories, id: \.path) { directory in
                HStack(spacing: 8) {
                    Text(directory.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DashboardTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if removableDirectories.contains(directory.path) {
                        Button {
                            onRemove(directory)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DashboardTheme.mutedText)
                        .accessibilityLabel(L10n.text("datasource.remove_folder"))
                    }
                }
                .padding(.leading, 20)
            }
        }
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
