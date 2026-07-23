import SwiftUI

/// Dashboard Data Sources: live status of each local source UsageDock reads,
/// per-provider onboarding (automatic for everything except Z.ai's API key),
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
                    PanelHeader(title: "数据来源状态")
                        .padding(.bottom, 4)
                    Text("这里只显示至少成功连接过一次的应用；链路或凭据后来失效时仍会保留，并标记为“数据链失效”。")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                    if visibleSources.isEmpty {
                        Text("尚无成功连接过的数据来源")
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
                        Label("最近一次刷新的诊断信息", systemImage: "exclamationmark.triangle.fill")
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
                    PanelHeader(title: "隐私")
                    RoadmapList(items: [
                        "本机用量数据全部留在本地，TokenRemain 不做任何上传。",
                        "所有工具凭证均为只读：绝不刷新 token、绝不写回，认证始终由各工具自行处理。",
                        "Z.ai API Key 仅保存在本机钥匙串，不进入源码、日志或任何网络请求（额度查询本身除外）。",
                        "ccusage 成本是 API 标价估算，不等于订阅账单。",
                        "AI 精选动态由内置策略自动同步；用户无需选择账号或管理数据源。"
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

    /// Provider 用持久化的成功连接历史过滤；内置来源只有在确实产出过
    /// 数据后才出现，避免把“支持但从未工作过”误呈现成已连接。
    private var visibleSources: [VisibleSource] {
        var sources = store.connectedProviders.map(VisibleSource.provider)
        if insights.daily != nil { sources.append(.ccusage) }
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
                detail: "npx ccusage 统计本地日志中的 token 与预估成本",
                healthy: true,
                capturedAt: insights.daily?.capturedAt
            )
        case .feed:
            SourceHealthRow(
                name: "AI 精选动态",
                detail: feedSourceDetail,
                healthy: true,
                capturedAt: feedStore.lastUpdated
            )
        }
    }

    @ViewBuilder
    private func providerCredentialRow(for provider: ProviderQuota.Provider) -> some View {
        switch provider {
        case .openrouter:
            APIKeyRow(
                store: store,
                provider: provider,
                placeholder: "粘贴 OpenRouter API Key（openrouter.ai → Keys 页生成）",
                hasStoredKey: OpenRouterKeyStore().hasStoredKey()
            )
        case .zai:
            APIKeyRow(
                store: store,
                provider: provider,
                placeholder: "粘贴 Z.ai API Key（z.ai → API Keys 页生成）",
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
        case .grok: return "Grok（xAI）"
        case .zai: return "Z.ai（GLM Coding Plan）"
        default: return provider.displayName
        }
    }

    private func sourceDetail(for provider: ProviderQuota.Provider) -> String {
        switch provider {
        case .claude: return "官方 oauth/usage 接口直查（只读本机凭证）；异常时回退 /usage 探针"
        case .codex: return "服务端实时接口直查（只读 ~/.codex/auth.json）；离线回退本地会话快照"
        case .cursor: return "月度账期接口直查（只读 Cursor 本机登录态）"
        case .copilot: return "GitHub copilot_internal 接口直查（只读本机 GitHub 登录）"
        case .devin: return "SeatManagement 接口直查（只读本机 Devin 凭证）"
        case .grok: return "周池额度接口直查（只读 ~/.grok/auth.json）"
        case .openrouter: return "预充积分接口直查（API Key 存于本机钥匙串）"
        case .antigravity: return "Cloud Code 配额池直查（只读本机登录态，绝不代刷）"
        case .opencode: return "本地数据库扫描估算 Go 套餐额度（纯本地，无网络）"
        case .zai: return "额度接口直查（API Key 存于本机钥匙串）"
        case .kiro: return "kiro-cli /usage 报告解析（本机子进程）"
        case .ollama: return "本机 Ollama 运行状态与模型信息（纯本地）"
        default: return "额度接口直查（凭据存于本机钥匙串）"
        }
    }

    private var rowDivider: some View {
        Divider().overlay(DashboardTheme.border).padding(.vertical, 12)
    }

    private var feedSourceDetail: String {
        feedStore.lastUpdated == nil
            ? "等待后台同步精选内容"
            : "后台自动筛选额度、产品发布与服务状态更新"
    }
}

/// 需要 API Key 的 provider(Z.ai / OpenRouter)的一次性接入入口:
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
            SecureField(hasStoredKey ? "已保存（粘贴新 Key 可替换）" : placeholder, text: $draftKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .disabled(isSaving)

            Button(hasStoredKey ? "替换" : "保存") {
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
                Button("清除") {
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
        .accessibilityLabel("\(provider.displayName) API Key 设置")
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
                Text(healthy ? "正常" : "数据链失效")
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
