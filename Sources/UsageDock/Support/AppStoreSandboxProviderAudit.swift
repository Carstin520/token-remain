import Foundation

#if TOKENREMAIN_APP_STORE_CANDIDATE
/// A release-engineering probe used to compare the exact same provider code
/// before and after App Sandbox is applied. It deliberately emits only provider
/// names, outcome classes, timestamps, window sizes, and sanitized errors.
/// Credentials, payloads, account identifiers, file contents, and paths are
/// never included in the report.
enum AppStoreSandboxProviderAudit {
    struct Record: Codable, Sendable {
        let provider: String
        let outcome: String
        let errorType: String?
        let errorDomain: String?
        let errorCode: Int?
        let detail: String?
        let capturedAt: Date?
        let primaryWindowMinutes: Int?
    }

    struct Report: Codable, Sendable {
        let schemaVersion: Int
        let environment: String
        let generatedAt: Date
        let records: [Record]
    }

    static func run(environment: String) async -> Data {
        let records = await withTaskGroup(of: Record.self) { group in
            for provider in ProviderQuota.Provider.displayOrder {
                group.addTask {
                    do {
                        let quota = try await fetch(provider)
                        return Record(
                            provider: provider.rawValue,
                            outcome: "success",
                            errorType: nil,
                            errorDomain: nil,
                            errorCode: nil,
                            detail: nil,
                            capturedAt: quota.capturedAt,
                            primaryWindowMinutes: quota.primary.windowMinutes
                        )
                    } catch {
                        let nsError = error as NSError
                        return Record(
                            provider: provider.rawValue,
                            outcome: "failure",
                            errorType: String(reflecting: type(of: error)),
                            errorDomain: nsError.domain,
                            errorCode: nsError.code,
                            detail: safeDescription(error),
                            capturedAt: nil,
                            primaryWindowMinutes: nil
                        )
                    }
                }
            }
            var collected: [Record] = []
            for await record in group {
                collected.append(record)
            }
            collected.append(await auditLocalUsageHistory())
            let order = Dictionary(
                uniqueKeysWithValues: ProviderQuota.Provider.displayOrder.enumerated().map {
                    ($0.element.rawValue, $0.offset)
                }
            )
            return collected.sorted {
                (order[$0.provider] ?? ProviderQuota.Provider.displayOrder.count)
                    < (order[$1.provider] ?? ProviderQuota.Provider.displayOrder.count)
            }
        }

        let report = Report(
            schemaVersion: 1,
            environment: environment,
            generatedAt: .now,
            records: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(report)) ?? Data()
    }

    private static func fetch(_ provider: ProviderQuota.Provider) async throws -> ProviderQuota {
        switch provider {
        case .claude: return try await ClaudeUsageService().fetch()
        case .codex: return try await CodexUsageService().fetch(preferAPI: true)
        case .cursor: return try await CursorUsageService().fetch()
        case .grok: return try await GrokUsageService().fetch()
        case .zai: return try await ZAIUsageService().fetch()
        case .copilot: return try await CopilotUsageService().fetch()
        case .devin: return try await DevinUsageService().fetch()
        case .openrouter: return try await OpenRouterUsageService().fetch()
        case .antigravity: return try await AntigravityUsageService().fetch()
        case .opencode: return try await OpenCodeUsageService().fetch()
        case .deepseek: return try await DeepSeekUsageService().fetch()
        case .kimi: return try await KimiUsageService().fetch()
        case .minimax: return try await MiniMaxUsageService().fetch()
        case .mimo: return try await MiMoUsageService().fetch()
        case .qoder: return try await QoderUsageService().fetch()
        case .kiro: return try await KiroUsageService().fetch()
        case .volcengine: return try await VolcengineUsageService().fetch()
        case .ollama: return try await OllamaUsageService().fetch()
        }
    }

    private static func safeDescription(_ error: Error) -> String {
        if error is ProcessRunner.Failure {
            return "A required helper process failed."
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return String(error.localizedDescription.prefix(320))
            .replacingOccurrences(of: home, with: "~")
    }

    private static func auditLocalUsageHistory() async -> Record {
        do {
            let history = try await CCUsageService().fetchHistory(days: 30)
            return Record(
                provider: "Local usage/history (ccusage)",
                outcome: "success",
                errorType: nil,
                errorDomain: nil,
                errorCode: nil,
                detail: nil,
                capturedAt: history.capturedAt,
                primaryWindowMinutes: nil
            )
        } catch {
            let nsError = error as NSError
            return Record(
                provider: "Local usage/history (ccusage)",
                outcome: "failure",
                errorType: String(reflecting: type(of: error)),
                errorDomain: nsError.domain,
                errorCode: nsError.code,
                detail: safeDescription(error),
                capturedAt: nil,
                primaryWindowMinutes: nil
            )
        }
    }
}
#endif
