import Foundation

/// Grok Bot is a separate weekly grant on the Cursor account, not Grok CLI
/// credits or Cursor IDE's monthly pool. Only Cursor's own read-only auth reader
/// is reused; no login, token refresh or Grok Bot safeStorage import occurs.
struct GrokBotUsageService: Sendable {
    enum ServiceError: LocalizedError, Equatable {
        case notIncluded, organizationManaged, invalidResponse, requestFailed(Int)
        var errorDescription: String? {
            switch self {
            case .notIncluded: L10n.text("grokbot.not_included")
            case .organizationManaged: L10n.text("grokbot.organization_managed")
            case .invalidResponse: L10n.text("grokbot.unavailable")
            case .requestFailed(let status): L10n.format("service.common.request_failed_plain", "Grok Bot", status)
            }
        }
        var invalidatesQuota: Bool { self == .notIncluded || self == .organizationManaged }
    }

    static let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func fetch(now: Date = .now, timeout: TimeInterval = 25,
               readAuth: @escaping @Sendable () async -> CursorAuthReader.Auth? = { await CursorAuthReader().load() },
               perform: @escaping Transport = { try await URLSession.shared.data(for: $0) }) async throws -> ProviderQuota {
        // Includes local credential discovery and the single network request;
        // a stuck sqlite child is cancelled through ProcessRunner by the deadline.
        try await AsyncDeadline.run(timeout: timeout) {
            guard let auth = await readAuth() else { throw CursorUsageService.ServiceError.notLoggedIn }
            try Task.checkCancellation()
            if let expiry = JWT.expiry(auth.accessToken), expiry <= now { throw CursorUsageService.ServiceError.staleLogin }
            var request = URLRequest(url: Self.url)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 15
            request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            let (data, response) = try await perform(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
            switch http.statusCode {
            case 200: return try Self.parse(data, now: now)
            case 401, 403: throw CursorUsageService.ServiceError.staleLogin
            default: throw ServiceError.requestFailed(http.statusCode)
            }
        }
    }

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        struct Payload: Decodable {
            let usagePercent: Double?
            let hasNonZeroIncludedLimit: Bool?
            let includedLimitZero: Bool?
            let usesPooledEnterpriseAllowance: Bool?
            let nextResetTimestampUtc: String?
            let sandTrialExpiresAt: String?
            let grokPlanLabel: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw ServiceError.invalidResponse }
        if payload.usesPooledEnterpriseAllowance == true { throw ServiceError.organizationManaged }
        func date(_ value: String?) -> Date? {
            guard let value else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        let included = payload.includedLimitZero.map { !$0 } ?? payload.hasNonZeroIncludedLimit
        let trial = date(payload.sandTrialExpiresAt)
        let activeTrial = included != true && trial.map { $0 > now } == true
        if included == false && !activeTrial { throw ServiceError.notIncluded }
        guard included == true || activeTrial,
              let used = payload.usagePercent, used.isFinite, used >= 0 else { throw ServiceError.invalidResponse }
        var plan = payload.grokPlanLabel.map { String($0.prefix(80)) } ?? "Grok Bot"
        if activeTrial, let trial {
            plan = L10n.format("grokbot.trial", trial.formatted(date: .abbreviated, time: .omitted))
        }
        return ProviderQuota(provider: .grokBot,
            primary: QuotaWindow(usedPercent: min(100, used), windowMinutes: activeTrial ? 0 : 10_080,
                                 resetsAt: activeTrial ? nil : date(payload.nextResetTimestampUtc)),
            secondary: nil, planName: plan, capturedAt: now)
    }
}
