import Foundation

/// A provider-scoped view of its official public status-page components.
/// Unknown means TokenRemain could not verify the status; it is deliberately
/// not treated as a provider outage.
struct ProviderServiceStatus: Sendable, Equatable {
    enum Level: String, Sendable, CaseIterable {
        case operational
        case degradedPerformance
        case partialOutage
        case majorOutage
        case maintenance
        case unknown

        var isAbnormal: Bool {
            switch self {
            case .operational, .unknown: false
            case .degradedPerformance, .partialOutage, .majorOutage, .maintenance: true
            }
        }

        /// Kept on the status model so every value the provider can return has
        /// an explicit, testable explanation in the UI.
        var explanationLocalizationKey: String {
            switch self {
            case .operational: "service_status.description.operational"
            case .degradedPerformance: "service_status.description.degraded"
            case .partialOutage: "service_status.description.partial_outage"
            case .majorOutage: "service_status.description.major_outage"
            case .maintenance: "service_status.description.maintenance"
            case .unknown: "service_status.description.unknown"
            }
        }

        fileprivate var severity: Int {
            switch self {
            case .operational: 0
            case .unknown: 1
            case .maintenance: 2
            case .degradedPerformance: 3
            case .partialOutage: 4
            case .majorOutage: 5
            }
        }

        static func statusPageValue(_ value: String) -> Level {
            switch value.lowercased() {
            case "operational": .operational
            case "degraded_performance": .degradedPerformance
            case "partial_outage": .partialOutage
            case "major_outage": .majorOutage
            case "under_maintenance": .maintenance
            default: .unknown
            }
        }
    }

    let provider: ProviderQuota.Provider
    let level: Level
    let componentNames: [String]
    let affectedComponentNames: [String]
    let checkedAt: Date
    let statusPageURL: URL

    var isAbnormal: Bool { level.isAbnormal }

    static func unknown(
        provider: ProviderQuota.Provider,
        checkedAt: Date,
        statusPageURL: URL
    ) -> ProviderServiceStatus {
        ProviderServiceStatus(
            provider: provider,
            level: .unknown,
            componentNames: [],
            affectedComponentNames: [],
            checkedAt: checkedAt,
            statusPageURL: statusPageURL
        )
    }
}

enum ProviderStatusParser {
    enum ParseError: Error {
        case invalidPayload
    }

    private struct Payload: Decodable {
        let components: [Component]
    }

    private struct Component: Decodable {
        let name: String
        let status: String
    }

    static func parse(
        _ data: Data,
        provider: ProviderQuota.Provider,
        checkedAt: Date,
        statusPageURL: URL
    ) throws -> ProviderServiceStatus {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ParseError.invalidPayload
        }

        let components = payload.components.filter { isRelevant($0.name, to: provider) }
        guard !components.isEmpty else {
            return .unknown(
                provider: provider,
                checkedAt: checkedAt,
                statusPageURL: statusPageURL
            )
        }

        let levels = components.map { ProviderServiceStatus.Level.statusPageValue($0.status) }
        let worst = levels.max(by: { $0.severity < $1.severity }) ?? .unknown
        let affected = components.filter {
            ProviderServiceStatus.Level.statusPageValue($0.status) != .operational
        }

        return ProviderServiceStatus(
            provider: provider,
            level: worst,
            componentNames: components.map(\.name),
            affectedComponentNames: affected.map(\.name),
            checkedAt: checkedAt,
            statusPageURL: statusPageURL
        )
    }

    static func isRelevant(
        _ componentName: String,
        to provider: ProviderQuota.Provider
    ) -> Bool {
        let name = componentName.lowercased()
        switch provider {
        case .claude:
            return name == "claude code" || name == "claude api (api.anthropic.com)"
        case .codex:
            return name.contains("codex") || name == "cli" || name == "vs code extension"
        default:
            return false
        }
    }
}
