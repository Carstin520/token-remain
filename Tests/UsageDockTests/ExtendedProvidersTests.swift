import Foundation
import Testing
@testable import UsageDock

@Suite("Extended providers (token-monitor compat)")
struct ExtendedProvidersTests {
    @Test("DeepSeek balance keeps its availability meter and exposes a monetary value")
    func deepseek() throws {
        let payload = """
        {"is_available": true, "balance_infos": [
            {"currency": "CNY", "total_balance": "110.55"},
            {"currency": "USD", "total_balance": "0.00"}
        ]}
        """
        let quota = try DeepSeekUsageService.parse(Data(payload.utf8))
        #expect(quota.provider == .deepseek)
        #expect(quota.primary.usedPercent == 0)
        #expect(quota.primary.windowMinutes == 0)
        #expect(quota.planName == "余额 ¥110.55")
        #expect(quota.remainingBalance == QuotaBalance(amount: 110.55, currencyCode: "CNY"))
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 110.55, currencyCode: "CNY"))
        #expect(quota.remainingBalance?.displayText == "¥110.55")
        #expect(
            QuotaWindowRow.remainingValueText(
                remainingPercent: 100,
                remainingBalance: quota.remainingBalance
            ) == "¥110.55"
        )

        let exhausted = try DeepSeekUsageService.parse(
            Data(#"{"is_available": false, "balance_infos": []}"#.utf8)
        )
        #expect(exhausted.primary.usedPercent == 100)
        #expect(exhausted.remainingBalance?.displayText == "0.00")
    }

    @Test("Currency display covers CNY, USD, JPY, and unknown codes")
    func currencyDisplay() {
        #expect(QuotaBalance(amount: 12.3, currencyCode: "CNY").displayText == "¥12.30")
        #expect(QuotaBalance(amount: 12.3, currencyCode: "usd").displayText == "$12.30")
        #expect(QuotaBalance(amount: 12.3, currencyCode: " JPY ").displayText == "¥12.30")
        #expect(QuotaBalance(amount: 12.3, currencyCode: "USDT").displayText == "USDT 12.30")
        #expect(QuotaBalance(amount: .infinity, currencyCode: "USD").displayText == "$0.00")
    }

    @Test("DeepSeek keeps the first positive balance when both official currencies are funded")
    func deepseekDualCurrency() throws {
        let payload = """
        {"is_available": true, "balance_infos": [
            {"currency": "USD", "total_balance": "4.25"},
            {"currency": "CNY", "total_balance": "30.00"}
        ]}
        """
        let quota = try DeepSeekUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 4.25, currencyCode: "USD"))
        #expect(quota.primary.remainingBalance?.displayText == "$4.25")
        #expect(quota.primary.usedPercent == 0)
    }

    @Test("Kimi limits entries split into session and weekly windows")
    func kimi() throws {
        let payload = """
        {"limits": [
            {"detail": {"used": 30, "limit": 100, "resetTime": 1784005200000},
             "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}},
            {"detail": {"percent": 55},
             "window": {"duration": 1, "timeUnit": "TIME_UNIT_WEEK"}}
        ]}
        """
        let quota = try KimiUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 30)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_784_005_200))
        #expect(quota.secondary?.usedPercent == 55)
        #expect(quota.secondary?.windowMinutes == 10_080)
    }

    @Test("MiniMax general lane flips remaining percents into windows")
    func minimax() throws {
        let payload = """
        {"data": {"model_remains": [
            {"model_name": "video", "current_interval_remaining_percent": "0"},
            {"model_name": "general",
             "current_interval_remaining_percent": "72.5", "end_time": 1784005200000,
             "current_weekly_remaining_percent": "40", "weekly_end_time": 1784500000000}
        ]}}
        """
        let quota = try MiniMaxUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 27.5)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.usedPercent == 60)
    }

    @Test("MiMo month_total_token is found anywhere in the payload")
    func mimo() throws {
        let payload = """
        {"data": {"items": [
            {"name": "day_token", "used": 1, "limit": 10},
            {"name": "month_total_token", "used": 250, "limit": 1000}
        ]}}
        """
        let quota = try MiMoUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.primary.windowMinutes == 43_200)
    }

    @Test("Qoder merges total and shared credit pools")
    func qoder() throws {
        let payload = """
        {"totalQuota": {"quotaSummary": {"usedValue": 30, "limitValue": 100}},
         "sharedQuota": {"quotaSummary": {"usedValue": 10, "limitValue": 100}}}
        """
        let quota = try QoderUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 20)
    }

    @Test("Kiro CLI report parses bar percent, credits fallback, and reset date")
    func kiro() throws {
        let bar = "Plan: Free\n█████░░░░░ 42%\ncredits resets on 2026-08-01"
        let quota = try KiroUsageService.parse(bar)
        #expect(quota.primary.usedPercent == 42)
        #expect(quota.primary.resetsAt != nil)

        let credits = "Usage (12.5 of 50 covered)"
        #expect(try KiroUsageService.parse(credits).primary.usedPercent == 25)
    }

    @Test("Volcengine result percent is found in nested Result payloads")
    func volcengine() throws {
        let payload = #"{"Result": {"user_limit": {"Percent": 66}}}"#
        let quota = try VolcengineUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 66)
    }

    @Test("Ollama settings HTML yields session and weekly windows")
    func ollama() throws {
        let html = """
        <div>Session usage</div><div>12.5% used</div>
        <div>Weekly usage</div><div>40% used</div>
        """
        let quota = try OllamaUsageService.parse(html)
        #expect(quota.primary.usedPercent == 12.5)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.usedPercent == 40)
    }

    @Test("Secret store prefers environment variables and persists to keychain descriptor")
    func secretStoreEnv() {
        var store = ProviderSecretStore(provider: .deepseek)
        store.environment = ["DEEPSEEK_API_KEY": " sk-ds "]
        #expect(store.load() == "sk-ds")
        #expect(ProviderSecretStore.descriptor(for: .kiro) == nil)
        #expect(ProviderSecretStore.descriptors.count == 7)
        #expect(ProviderCredentialConfiguration.resolve(for: .zai)?.isCookie == false)
        #expect(ProviderCredentialConfiguration.resolve(for: .deepseek)?.isCookie == false)
        #expect(ProviderCredentialConfiguration.resolve(for: .mimo)?.isCookie == true)
        #expect(ProviderCredentialConfiguration.resolve(for: .claude) == nil)
    }

    @Test("Quota cache round-trips the dictionary format and reads legacy fields")
    func quotaCacheFormats() throws {
        let quota = ProviderQuota(
            provider: .kimi,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: Date(timeIntervalSince1970: 1_784_000_000),
            remainingBalance: QuotaBalance(amount: 12.34, currencyCode: "USD")
        )
        let snapshot = QuotaCache.Snapshot(byProvider: [.kimi: quota])
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(QuotaCache.Snapshot.self, from: encoded)
        #expect(decoded.byProvider[.kimi]?.primary.usedPercent == 10)
        #expect(decoded.byProvider[.kimi]?.remainingBalance?.displayText == "$12.34")

        // v1 逐字段格式仍可读。
        let legacy = """
        {"claude": {"provider": "Claude Code",
                    "primary": {"usedPercent": 5, "windowMinutes": 300},
                    "capturedAt": 700000000}}
        """
        let migrated = try JSONDecoder().decode(QuotaCache.Snapshot.self, from: Data(legacy.utf8))
        #expect(migrated.byProvider[.claude]?.primary.usedPercent == 5)
        #expect(migrated.byProvider[.claude]?.remainingBalance == nil)
    }
}
