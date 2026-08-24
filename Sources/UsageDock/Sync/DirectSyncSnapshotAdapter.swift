import Foundation
import TokenRemainSyncKit

enum DirectSyncSnapshotAdapter {
    static func quotas(from snapshot: MobileUsageSnapshot) -> [ProviderQuota.Provider: ProviderQuota] {
        Dictionary(uniqueKeysWithValues: snapshot.providers.compactMap { source in
            guard source.statusCode == .available,
                  let provider = provider(for: source.providerID) else { return nil }
            let windows = source.windows.enumerated()
                .filter { $0.element.usedPercent.isFinite && (0...100).contains($0.element.usedPercent) }
                .sorted { lhs, rhs in
                    let lhsMinutes = lhs.element.windowMinutes == 0 ? Int.max : lhs.element.windowMinutes
                    let rhsMinutes = rhs.element.windowMinutes == 0 ? Int.max : rhs.element.windowMinutes
                    return lhsMinutes == rhsMinutes ? lhs.offset < rhs.offset : lhsMinutes < rhsMinutes
                }
                .map(\.element)
            guard let primary = windows.first else { return nil }
            let quota = ProviderQuota(
                provider: provider,
                primary: quotaWindow(primary),
                secondary: windows.dropFirst().first.map(quotaWindow),
                planName: source.planName,
                capturedAt: source.capturedAt,
                scopedWindows: source.scopedWindows?.map {
                    ScopedQuotaWindow(
                        scopeID: $0.scopeID,
                        displayName: $0.displayName,
                        window: quotaWindow($0.window)
                    )
                }
            )
            return (provider, quota)
        })
    }

    private static func quotaWindow(_ source: SyncedQuotaWindow) -> QuotaWindow {
        QuotaWindow(
            usedPercent: source.usedPercent,
            windowMinutes: source.windowMinutes,
            resetsAt: source.resetsAt,
            remainingBalance: source.remainingBalance.map {
                QuotaBalance(amount: $0.amount, currencyCode: $0.currencyCode)
            }
        )
    }

    private static func provider(for identifier: String) -> ProviderQuota.Provider? {
        switch identifier {
        case SyncedProviderID.claude: .claude
        case SyncedProviderID.codex: .codex
        case SyncedProviderID.cursor: .cursor
        case SyncedProviderID.grok: .grok
        case SyncedProviderID.zai: .zai
        case SyncedProviderID.copilot: .copilot
        case SyncedProviderID.devin: .devin
        case SyncedProviderID.windsurf: .windsurf
        case SyncedProviderID.openrouter: .openrouter
        case SyncedProviderID.antigravity: .antigravity
        case SyncedProviderID.opencode: .opencode
        case SyncedProviderID.deepseek: .deepseek
        case SyncedProviderID.kimi: .kimi
        case SyncedProviderID.minimax: .minimax
        case SyncedProviderID.mimo: .mimo
        case SyncedProviderID.qoder: .qoder
        case SyncedProviderID.kiro: .kiro
        case SyncedProviderID.volcengine: .volcengine
        case SyncedProviderID.ollama: .ollama
        default: nil
        }
    }
}
