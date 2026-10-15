import Foundation

// Providers whose only usage source is the user's own signed-in web session.
// Every service here reads a Cookie header the user pasted (Data Sources or the
// Cookie guide) from TokenRemain's own Keychain; none imports browser cookie
// stores, follows a login redirect, or refreshes a session. Endpoints follow
// CodexBar's providers (MIT), re-implemented for TokenRemain's models.

// MARK: - Muse Code (dev.meta.ai)

/// Meta Muse Code subscription (Everyday / High / Power Usage): a rolling
/// 5-hour request window plus a weekly limit, both as weighted usage. Read from
/// the dev.meta.ai usage page's own GET endpoints with the web session. The
/// CLI's `POST /muse-code/key` is deliberately not used: it may mint an API key.
///
/// Quota is per team. With a team chosen in Data Sources only that team is
/// read — the numbers never silently switch to another team. Without a choice
/// (or when the chosen team is gone) the first team carrying a subscription
/// quota is used, as before.
struct MuseCodeUsageService {
    static let origin = URL(string: "https://dev.meta.ai")!
    /// Teams tried in automatic mode; the first one carrying a quota wins.
    static let maxTeams = 3

    var teamStore = MuseCodeTeamStore()
    /// GET of a dev.meta.ai path with the session Cookie; injectable for tests.
    var get: @Sendable (_ path: String, _ cookie: String) async throws -> Data = { path, cookie in
        try await ExtendedHTTP.request(
            .museCode,
            url: URL(string: path, relativeTo: MuseCodeUsageService.origin)!.absoluteURL,
            headers: WebSessionCookie.headers(cookie: cookie, origin: MuseCodeUsageService.origin),
            followRedirects: false
        )
    }

    enum ServiceError: LocalizedError, Sendable, Equatable {
        case selectedTeamHasNoQuota(String)

        var errorDescription: String? {
            switch self {
            case .selectedTeamHasNoQuota(let name):
                L10n.format("service.muse_code.team_no_quota", name)
            }
        }
    }

    func fetch(cookie: String? = nil, now: Date = .now) async throws -> ProviderQuota {
        let header = try WebSessionCookie.load(.museCode, supplied: cookie)
        let teams = try MuseCodeUsageParser.teams(try await get("/api/portal/teams", header))
        guard !teams.isEmpty else { throw ExtendedProviderError.invalidResponse(.museCode) }
        teamStore.saveKnownTeams(teams)

        let label = teams.count > 1
        if let selectedID = teamStore.selectedTeamID() {
            if let team = teams.first(where: { $0.id == selectedID }) {
                let data = try await get("/api/portal/teams/\(team.id)/subscription-quota", header)
                guard let quota = try MuseCodeUsageParser.parseQuota(
                    data, teamName: label ? team.name : nil, now: now
                ) else {
                    throw ServiceError.selectedTeamHasNoQuota(team.name)
                }
                return quota
            }
            // The chosen team is gone (left or renamed id): back to automatic.
            teamStore.saveSelectedTeamID(nil)
        }

        var lastError: Error = ExtendedProviderError.invalidResponse(.museCode)
        for team in teams.prefix(Self.maxTeams) {
            try Task.checkCancellation()
            do {
                let data = try await get("/api/portal/teams/\(team.id)/subscription-quota", header)
                if let quota = try MuseCodeUsageParser.parseQuota(
                    data, teamName: label ? team.name : nil, now: now
                ) {
                    return quota
                }
            } catch let error as ExtendedProviderError {
                if case .secretRejected = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}

/// The Muse Code team choice and the team list last seen. Neither is a
/// credential, so both live in UserDefaults; the session Cookie stays in the
/// app-owned Keychain.
struct MuseCodeTeam: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
}

struct MuseCodeTeamStore: Sendable {
    static let selectedKey = "tokenRemain.museCode.selectedTeam.v1"
    static let knownTeamsKey = "tokenRemain.museCode.knownTeams.v1"

    var defaults: @Sendable () -> UserDefaults = { .standard }

    func selectedTeamID() -> String? {
        defaults().string(forKey: Self.selectedKey)
    }

    func saveSelectedTeamID(_ id: String?) {
        if let id { defaults().set(id, forKey: Self.selectedKey) } else { defaults().removeObject(forKey: Self.selectedKey) }
    }

    func knownTeams() -> [MuseCodeTeam] {
        guard let data = defaults().data(forKey: Self.knownTeamsKey) else { return [] }
        return (try? JSONDecoder().decode([MuseCodeTeam].self, from: data)) ?? []
    }

    func saveKnownTeams(_ teams: [MuseCodeTeam]) {
        guard let data = try? JSONEncoder().encode(teams) else { return }
        defaults().set(data, forKey: Self.knownTeamsKey)
    }

    /// Clearing the Cookie forgets the account's teams and the choice with it.
    func clear() {
        defaults().removeObject(forKey: Self.selectedKey)
        defaults().removeObject(forKey: Self.knownTeamsKey)
    }
}

enum MuseCodeUsageParser {
    static func teams(_ data: Data) throws -> [MuseCodeTeam] {
        guard let body = ExtendedHTTP.json(data), let teams = body["teams"] as? [[String: Any]] else {
            throw ExtendedProviderError.invalidResponse(.museCode)
        }
        return teams.compactMap { item in
            guard let id = numericID(item["team_id"]) else { return nil }
            let name = (item["team_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MuseCodeTeam(id: id, name: name?.isEmpty == false ? name! : id)
        }
    }

    /// nil = this team has no subscription quota (try the next team).
    /// `teamName` is shown beside the plan when the account has several teams.
    static func parseQuota(_ data: Data, teamName: String? = nil, now: Date = .now) throws -> ProviderQuota? {
        guard let body = ExtendedHTTP.json(data) else {
            throw ExtendedProviderError.invalidResponse(.museCode)
        }
        guard let quota = body["subscription_quota"] as? [String: Any] else { return nil }
        guard let weeklyPercent = percent(quota["weekly_weighted_used"], quota["weekly_weighted_limit"]),
              let windowSeconds = amount(quota["window_duration_secs"]), windowSeconds >= 60,
              var windowPercent = percent(quota["window_weighted_used"], quota["window_weighted_limit"]) else {
            throw ExtendedProviderError.invalidResponse(.museCode)
        }
        let weeklyReset = date(quota["weekly_resets_at"])
        // An idle 5-hour window has no reset time; one whose reset has passed
        // carries no usage into the next window.
        let windowReset = date(quota["window_resets_at"]).flatMap { $0 > now ? $0 : nil }
        if windowReset == nil { windowPercent = 0 }
        let tier = (quota["tier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = [tier?.isEmpty == false ? tier : nil, teamName].compactMap { $0 }.joined(separator: " · ")
        return ProviderQuota(
            provider: .museCode,
            primary: QuotaWindow(
                usedPercent: windowPercent,
                windowMinutes: Int((windowSeconds / 60).rounded()),
                resetsAt: windowReset
            ),
            secondary: QuotaWindow(usedPercent: weeklyPercent, windowMinutes: 10_080, resetsAt: weeklyReset),
            planName: plan.isEmpty ? nil : plan,
            capturedAt: now
        )
    }

    /// Weighted counts arrive as decimal strings (or numbers).
    private static func amount(_ value: Any?) -> Double? {
        if let text = value as? String, text.allSatisfy(\.isNumber), let number = Double(text) { return number }
        if let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 {
            return number.doubleValue
        }
        return nil
    }

    private static func percent(_ used: Any?, _ limit: Any?) -> Double? {
        guard let used = amount(used), let limit = amount(limit), limit > 0 else { return nil }
        return min(100, used / limit * 100)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let seconds = amount(value), seconds > 0, seconds < 64_092_211_200 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func numericID(_ value: Any?) -> String? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespaces),
           !text.isEmpty, text.allSatisfy(\.isNumber) {
            return text
        }
        if let number = value as? NSNumber, number.doubleValue.rounded() == number.doubleValue, number.int64Value > 0 {
            return String(number.int64Value)
        }
        return nil
    }
}

// MARK: - Amp (ampcode.com)

/// Amp's balance summary — the same text `amp usage` prints. The Amp CLI's own
/// API key is preferred (`AMP_API_KEY`, then the CLI's `secrets.json`), read
/// only and never written back. Without it, the pasted ampcode.com session
/// Cookie reads the same summary through the web app's internal API, with the
/// Amp Free object embedded in the settings page as the last fallback.
struct AmpUsageService {
    static let origin = URL(string: "https://ampcode.com")!
    static let settingsURL = URL(string: "https://ampcode.com/settings")!
    static let balanceURL = URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!
    private static let balanceBody = Data(#"{"method":"userDisplayBalanceInfo","params":{}}"#.utf8)

    var cliCredential: @Sendable () -> String? = { AmpCLICredentialReader().load() }

    /// `cookie` is set when Data Sources validates a pasted Cookie: that path
    /// must test the Cookie itself, not the CLI key.
    func fetch(cookie: String? = nil, now: Date = .now) async throws -> ProviderQuota {
        if cookie == nil, let apiKey = cliCredential() {
            do {
                return try await fetchWithAPIKey(apiKey, now: now)
            } catch let error as ExtendedProviderError {
                // A rejected CLI key falls back to a saved Cookie when there is one.
                guard case .secretRejected = error,
                      ProviderSecretStore(provider: .amp).load() != nil else { throw error }
            }
        }
        return try await fetchWithCookie(try WebSessionCookie.load(.amp, supplied: cookie), now: now)
    }

    private func fetchWithAPIKey(_ apiKey: String, now: Date) async throws -> ProviderQuota {
        let data = try await ExtendedHTTP.request(
            .amp, url: Self.balanceURL, method: "POST",
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
                "Content-Type": "application/json"
            ],
            body: Self.balanceBody, followRedirects: false
        )
        return try AmpUsageParser.parseBalanceResponse(data, now: now)
    }

    private func fetchWithCookie(_ header: String, now: Date) async throws -> ProviderQuota {
        var headers = WebSessionCookie.headers(cookie: header, origin: Self.origin)
        headers["Referer"] = Self.settingsURL.absoluteString
        headers["Content-Type"] = "application/json"
        if let data = try? await ExtendedHTTP.request(
            .amp, url: Self.balanceURL, method: "POST", headers: headers, body: Self.balanceBody,
            followRedirects: false
        ), let quota = try? AmpUsageParser.parseBalanceResponse(data, now: now) {
            return quota
        }
        try Task.checkCancellation()
        var pageHeaders = WebSessionCookie.headers(cookie: header, origin: Self.origin)
        pageHeaders["Accept"] = "text/html"
        let page = try await ExtendedHTTP.request(
            .amp, url: Self.settingsURL, headers: pageHeaders, followRedirects: false
        )
        return try AmpUsageParser.parseSettingsPage(String(decoding: page, as: UTF8.self), now: now)
    }
}

/// Read-only discovery of the Amp CLI's API key: `AMP_API_KEY`, then
/// `$XDG_DATA_HOME/amp/secrets.json` (default `~/.local/share/amp`), whose key
/// the CLI stores as `apiKey@https://ampcode.com/`. Never written, refreshed or
/// logged; the value stays in memory for the one request.
struct AmpCLICredentialReader {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    static let maxFileBytes = 64 * 1024

    var secretsURL: URL {
        let base = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".local/share")
        return base.appending(path: "amp/secrets.json")
    }

    func load() -> String? {
        if let key = normalized(environment["AMP_API_KEY"]) { return key }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: secretsURL.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maxFileBytes,
              let data = try? Data(contentsOf: secretsURL) else { return nil }
        return Self.apiKey(fromSecrets: data)
    }

    /// Whether a CLI key is available, for detection; never returns the key.
    var isAvailable: Bool { load() != nil }

    /// Prefers the ampcode.com entry, then any other `apiKey…` entry.
    static func apiKey(fromSecrets data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let candidates = object
            .filter { $0.key.hasPrefix("apiKey") }
            .sorted { lhs, rhs in
                let l = lhs.key.contains("ampcode.com"), r = rhs.key.contains("ampcode.com")
                return l != r ? l : lhs.key < rhs.key
            }
        for (_, value) in candidates {
            if let key = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty, !key.contains(where: \.isWhitespace) {
                return key
            }
        }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}

enum AmpUsageParser {
    static func parseBalanceResponse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data) else { throw ExtendedProviderError.invalidResponse(.amp) }
        if body["ok"] as? Bool == false {
            let code = (body["error"] as? [String: Any])?["code"] as? String
            throw code == "auth-required"
                ? ExtendedProviderError.secretRejected(.amp, 401)
                : ExtendedProviderError.invalidResponse(.amp)
        }
        guard let text = (body["result"] as? [String: Any])?["displayText"] as? String else {
            throw ExtendedProviderError.invalidResponse(.amp)
        }
        return try parse(displayText: text, now: now)
    }

    /// Subset of `amp usage` output: Amp Free, a paid tier's agent dollars or
    /// the percentage subscription line, and individual credits.
    static func parse(displayText raw: String, now: Date = .now) throws -> ProviderQuota {
        let text = raw.replacingOccurrences(of: "**", with: "")
        let amount = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#

        var free: QuotaWindow?
        if let match = captures(#"(?im)^\s*Amp Free:\s*\$?"# + amount + #"\s*/\s*\$?"# + amount
            + #"\s+remaining(?:\s*\(replenishes\s*\+\$?"# + amount + #"\s*/\s*hour\))?"#, in: text),
           let remaining = number(match[0]), let quota = number(match[1]), quota > 0 {
            let hourly = number(match[2]) ?? 0
            let hours = hourly > 0 ? max(1, (quota / hourly).rounded()) : 24
            free = QuotaWindow(
                usedPercent: ExtendedHTTP.clamp((quota - remaining) / quota * 100),
                windowMinutes: Int(hours * 60),
                resetsAt: nil
            )
        } else if let match = captures(#"(?im)^\s*Amp Free:\s*"# + amount + #"\s*%\s+remaining"#, in: text),
                  let remaining = number(match[0]) {
            free = QuotaWindow(usedPercent: ExtendedHTTP.clamp(100 - remaining), windowMinutes: 1440, resetsAt: nil)
        }

        var paid: QuotaWindow?
        var plan: String?
        if let match = captures(#"(?im)^\s*Amp\s+([^\r\n]+?)\s+Tier:\s*agent\s+usage\s+\$"# + amount
            + #"\s+of\s+\$"# + amount + #"\s+remaining\b[^\r\n]*?resets\s+upon\s+renewal\s+in\s+([0-9][0-9,]*)\s+(days?|months?)\b"#,
            in: text),
           let remaining = number(match[1]), let limit = number(match[2]), limit > 0 {
            plan = match[0]
            paid = QuotaWindow(
                usedPercent: ExtendedHTTP.clamp((limit - remaining) / limit * 100),
                windowMinutes: 43_200,
                resetsAt: renewal(value: match[3], unit: match[4], now: now)
            )
        } else if let match = captures(#"(?im)^\s*(?:Subscription\s+(.+?)|Amp\s+(.+?)\s+Subscription):\s*"# + amount
            + #"\s*%\s+other\s+usage\b[^\r\n]*?resets\s+upon\s+renewal\s+in\s+([0-9][0-9,]*)\s+(days?|months?)"#,
            in: text),
                  let remaining = number(match[2]) {
            plan = match[0].isEmpty ? match[1] : match[0]
            paid = QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(100 - remaining),
                windowMinutes: 43_200,
                resetsAt: renewal(value: match[3], unit: match[4], now: now)
            )
        }

        let credits = captures(#"(?im)^\s*Individual credits:\s*\$?"# + amount + #"\s+remaining"#, in: text)
            .flatMap { number($0[0]) }
        let balance = credits.map { QuotaBalance(amount: $0, currencyCode: "USD") }

        if let paid {
            return ProviderQuota(
                provider: .amp, primary: paid, secondary: nil,
                planName: plan, capturedAt: now, accountBalance: balance,
                scopedWindows: free.map {
                    [ScopedQuotaWindow(scopeID: "amp_free", displayName: "Amp Free", window: $0, observedAt: now)]
                }
            )
        }
        if let free {
            return ProviderQuota(
                provider: .amp, primary: free, secondary: nil,
                planName: "Amp Free", capturedAt: now, accountBalance: balance
            )
        }
        if let balance {
            // Credits only: the meter carries availability, the text the dollars.
            return ProviderQuota(
                provider: .amp,
                primary: QuotaWindow(
                    usedPercent: balance.amount > 0 ? 0 : 100,
                    windowMinutes: 0,
                    resetsAt: nil,
                    remainingBalance: balance
                ),
                secondary: nil, planName: nil, capturedAt: now
            )
        }
        throw ExtendedProviderError.invalidResponse(.amp)
    }

    /// Settings page fallback: `freeTierUsage: {quota, used, hourlyReplenishment, windowHours}`.
    static func parseSettingsPage(_ html: String, now: Date = .now) throws -> ProviderQuota {
        for token in ["freeTierUsage", "getFreeTierUsage"] {
            guard let start = html.range(of: token),
                  let brace = html[start.upperBound...].firstIndex(of: "{"),
                  let end = html[brace...].firstIndex(of: "}") else { continue }
            let object = String(html[brace...end])
            guard let quota = field("quota", in: object), quota > 0,
                  let used = field("used", in: object) else { continue }
            let hourly = field("hourlyReplenishment", in: object) ?? 0
            let hours = field("windowHours", in: object) ?? (hourly > 0 ? max(1, (quota / hourly).rounded()) : 24)
            return ProviderQuota(
                provider: .amp,
                primary: QuotaWindow(
                    usedPercent: ExtendedHTTP.clamp(used / quota * 100),
                    windowMinutes: max(1, Int(hours * 60)),
                    resetsAt: nil
                ),
                secondary: nil, planName: "Amp Free", capturedAt: now
            )
        }
        throw ExtendedProviderError.invalidResponse(.amp)
    }

    private static func field(_ name: String, in object: String) -> Double? {
        captures(#"["']?\#(name)["']?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, in: object).flatMap { number($0[0]) }
    }

    private static func renewal(value: String, unit: String, now: Date) -> Date? {
        guard let count = Int(value.replacingOccurrences(of: ",", with: "")), count >= 0, count < 10_000 else {
            return nil
        }
        return unit.lowercased().hasPrefix("month")
            ? Calendar(identifier: .gregorian).date(byAdding: .month, value: count, to: now)
            : now.addingTimeInterval(TimeInterval(count) * 86_400)
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    /// All capture groups of the first match; unmatched optional groups are "".
    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

// MARK: - Factory (app.factory.ai)

/// Factory (Droid) token allowance for the billing period: a Standard and a
/// Premium pool. The busier pool is the headline, the other a named sibling —
/// hiding either would mask whichever runs out first.
struct FactoryUsageService {
    static let apiOrigin = URL(string: "https://api.factory.ai")!
    static let appOrigin = URL(string: "https://app.factory.ai")!

    func fetch(cookie: String? = nil, now: Date = .now) async throws -> ProviderQuota {
        let header = try WebSessionCookie.load(.factory, supplied: cookie)
        var headers = WebSessionCookie.headers(cookie: header, origin: Self.appOrigin)
        headers["Referer"] = "https://app.factory.ai/"
        headers["x-factory-client"] = "web-app"
        // The web app also sends its session JWT as a bearer token.
        if let token = WebCookieHeader.value(named: "access-token", in: header), token.contains(".") {
            headers["Authorization"] = "Bearer \(token)"
        }
        var lastError: Error = ExtendedProviderError.invalidResponse(.factory)
        for base in [Self.apiOrigin, Self.appOrigin] {
            try Task.checkCancellation()
            var components = URLComponents(
                url: base.appendingPathComponent("/api/organization/subscription/usage"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "useCache", value: "true")]
            do {
                let data = try await ExtendedHTTP.request(
                    .factory, url: components.url!, headers: headers, followRedirects: false
                )
                return try FactoryUsageParser.parse(data, now: now)
            } catch let error as ExtendedProviderError {
                if case .secretRejected = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}

enum FactoryUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data), let usage = body["usage"] as? [String: Any] else {
            throw ExtendedProviderError.invalidResponse(.factory)
        }
        let start = ExtendedHTTP.number(usage["startDate"])
        let end = ExtendedHTTP.number(usage["endDate"])
        let resetsAt = end.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        let minutes: Int = {
            guard let start, let end, end > start else { return 43_200 }
            return max(1, Int((end - start) / 60_000))
        }()
        let pools: [(name: String, scopeID: String, percent: Double)] = [
            ("Standard", "factory_standard", usage["standard"]),
            ("Premium", "factory_premium", usage["premium"])
        ].compactMap { name, scopeID, raw in
            guard let pool = raw as? [String: Any], let percent = usedPercent(pool) else { return nil }
            return (name, scopeID, percent)
        }
        guard let busiest = pools.max(by: { $0.percent < $1.percent }) else {
            throw ExtendedProviderError.invalidResponse(.factory)
        }
        let others = pools.filter { $0.scopeID != busiest.scopeID }
        return ProviderQuota(
            provider: .factory,
            primary: QuotaWindow(
                usedPercent: busiest.percent,
                windowMinutes: minutes,
                resetsAt: resetsAt,
                poolName: pools.count > 1 ? busiest.name : nil
            ),
            secondary: nil,
            planName: nil,
            capturedAt: now,
            scopedWindows: others.isEmpty ? nil : others.map {
                ScopedQuotaWindow(
                    scopeID: $0.scopeID,
                    displayName: $0.name,
                    window: QuotaWindow(usedPercent: $0.percent, windowMinutes: minutes, resetsAt: resetsAt),
                    observedAt: now
                )
            }
        )
    }

    /// `usedRatio` (0…1) when present, else tokens used over the allowance.
    private static func usedPercent(_ pool: [String: Any]) -> Double? {
        if let ratio = ExtendedHTTP.number(pool["usedRatio"]), ratio.isFinite, ratio >= 0 {
            return ExtendedHTTP.clamp(ratio <= 1.5 ? ratio * 100 : ratio)
        }
        guard let allowance = ExtendedHTTP.number(pool["totalAllowance"]), allowance > 0,
              let used = ExtendedHTTP.number(pool["orgTotalTokensUsed"]) ?? ExtendedHTTP.number(pool["userTokens"])
        else { return nil }
        return ExtendedHTTP.clamp(used / allowance * 100)
    }
}

// MARK: - Augment (app.augmentcode.com)

/// Augment Code credits for the billing cycle (`/api/credits`), with the plan
/// name and cycle end from `/api/subscription` when available.
struct AugmentUsageService {
    static let origin = URL(string: "https://app.augmentcode.com")!

    func fetch(cookie: String? = nil, now: Date = .now) async throws -> ProviderQuota {
        let header = try WebSessionCookie.load(.augment, supplied: cookie)
        let headers = WebSessionCookie.headers(cookie: header, origin: Self.origin)
        let credits = try await ExtendedHTTP.request(
            .augment, url: Self.origin.appendingPathComponent("/api/credits"),
            headers: headers, followRedirects: false
        )
        try Task.checkCancellation()
        // The subscription call is optional detail; it never fails the refresh.
        let subscription = try? await ExtendedHTTP.request(
            .augment, url: Self.origin.appendingPathComponent("/api/subscription"),
            headers: headers, followRedirects: false
        )
        return try AugmentUsageParser.parse(credits: credits, subscription: subscription, now: now)
    }
}

enum AugmentUsageParser {
    static func parse(credits: Data, subscription: Data?, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(credits) else { throw ExtendedProviderError.invalidResponse(.augment) }
        let remaining = ExtendedHTTP.number(body["usageUnitsRemaining"])
        let consumed = ExtendedHTTP.number(body["usageUnitsConsumedThisBillingCycle"])
        let available = ExtendedHTTP.number(body["usageUnitsAvailable"])
        let limit: Double? = {
            if let available, available > 0 { return available }
            guard let remaining, let consumed else { return nil }
            return remaining + consumed
        }()
        guard let limit, limit > 0 else { throw ExtendedProviderError.invalidResponse(.augment) }
        let used = consumed ?? remaining.map { limit - $0 } ?? 0

        let details = subscription.flatMap(ExtendedHTTP.json)
        let plan = (details?["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let periodEnd = (details?["billingPeriodEnd"] as? String).flatMap(isoDate)

        var window = QuotaWindow(
            usedPercent: ExtendedHTTP.clamp(used / limit * 100),
            windowMinutes: 43_200,
            resetsAt: periodEnd
        )
        window.remainingCredits = remaining.map { max(0, $0) }
        return ProviderQuota(
            provider: .augment,
            primary: window,
            secondary: nil,
            planName: plan?.isEmpty == false ? plan : nil,
            capturedAt: now
        )
    }

    private static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - Shared

enum WebSessionCookie {
    /// Pasted header (or the app-owned Keychain copy), normalized.
    static func load(_ provider: ProviderQuota.Provider, supplied: String?) throws -> String {
        guard let raw = supplied ?? ProviderSecretStore(provider: provider).load() else {
            throw ExtendedProviderError.notConfigured(provider)
        }
        guard let header = WebCookieHeader.normalized(raw) else {
            throw ExtendedProviderError.invalidSecret(provider, detail: L10n.text("cookieguide.invalid_cookie"))
        }
        return header
    }

    static func headers(cookie: String, origin: URL) -> [String: String] {
        [
            "Cookie": cookie,
            "Accept": "application/json",
            "Origin": origin.absoluteString,
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        ]
    }
}
