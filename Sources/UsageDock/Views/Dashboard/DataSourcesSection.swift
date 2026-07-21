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
                    Text("除 Z.ai 外全部自动接入：登录对应工具后即自动读取本机凭证，无需在此配置。未接入时下方状态会给出具体指引。")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                    SourceHealthRow(
                        name: "Claude Code",
                        detail: "官方 oauth/usage 接口直查（只读本机凭证）；异常时回退 /usage 探针",
                        present: insights.claude != nil,
                        capturedAt: insights.claude?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "Codex",
                        detail: "服务端实时接口直查（只读 ~/.codex/auth.json）；离线回退本地会话快照",
                        present: insights.codex != nil,
                        capturedAt: insights.codex?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "Cursor",
                        detail: store.providerNotices[.cursor] ?? "月度账期接口直查（只读 Cursor 本机登录态）",
                        present: insights.cursor != nil,
                        capturedAt: insights.cursor?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "Copilot",
                        detail: store.providerNotices[.copilot] ?? "GitHub copilot_internal 接口直查（只读本机 GitHub 登录）",
                        present: insights.quota(for: .copilot) != nil,
                        capturedAt: insights.quota(for: .copilot)?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "Devin",
                        detail: store.providerNotices[.devin] ?? "SeatManagement 接口直查（只读本机 Devin 凭证）",
                        present: insights.quota(for: .devin) != nil,
                        capturedAt: insights.quota(for: .devin)?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "Grok（xAI）",
                        detail: store.providerNotices[.grok] ?? "周池额度接口直查（只读 ~/.grok/auth.json）",
                        present: insights.grok != nil,
                        capturedAt: insights.grok?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "OpenRouter",
                        detail: store.providerNotices[.openrouter] ?? "预充积分接口直查（API Key 存于本机钥匙串）",
                        present: insights.quota(for: .openrouter) != nil,
                        capturedAt: insights.quota(for: .openrouter)?.capturedAt
                    )
                    APIKeyRow(
                        store: store,
                        provider: .openrouter,
                        placeholder: "粘贴 OpenRouter API Key（openrouter.ai → Keys 页生成）",
                        hasStoredKey: OpenRouterKeyStore().hasStoredKey()
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "Antigravity",
                        detail: store.providerNotices[.antigravity] ?? "Cloud Code 配额池直查（只读本机登录态，绝不代刷）",
                        present: insights.quota(for: .antigravity) != nil,
                        capturedAt: insights.quota(for: .antigravity)?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "OpenCode",
                        detail: store.providerNotices[.opencode] ?? "本地数据库扫描估算 Go 套餐额度（纯本地，无网络）",
                        present: insights.quota(for: .opencode) != nil,
                        capturedAt: insights.quota(for: .opencode)?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "Z.ai（GLM Coding Plan）",
                        detail: store.providerNotices[.zai] ?? "额度接口直查（API Key 存于本机钥匙串）",
                        present: insights.zai != nil,
                        capturedAt: insights.zai?.capturedAt
                    )
                    APIKeyRow(
                        store: store,
                        provider: .zai,
                        placeholder: "粘贴 Z.ai API Key（z.ai → API Keys 页生成）",
                        hasStoredKey: ZAIKeyStore().hasStoredKey()
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "ccusage",
                        detail: "npx ccusage 统计本地日志中的 token 与预估成本",
                        present: insights.daily != nil,
                        capturedAt: insights.daily?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "AI 精选动态",
                        detail: feedSourceDetail,
                        present: feedStore.lastUpdated != nil,
                        capturedAt: feedStore.lastUpdated
                    )
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
                        "本机用量数据全部留在本地，Token Remain 不做任何上传。",
                        "所有工具凭证均为只读：绝不刷新 token、绝不写回，认证始终由各工具自行处理。",
                        "Z.ai API Key 仅保存在本机钥匙串，不进入源码、日志或任何网络请求（额度查询本身除外）。",
                        "ccusage 成本是 API 标价估算，不等于订阅账单。",
                        "AI 精选动态由内置策略自动同步；用户无需选择账号或管理数据源。"
                    ])
                }
            }
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
        default: return false
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
    let present: Bool
    let capturedAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(present ? DashboardTheme.success : DashboardTheme.mutedText)
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
                Text(present ? "正常" : "暂无数据")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(present ? DashboardTheme.success : DashboardTheme.mutedText)
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
