import Foundation

struct CCUsageService {
    private let pricingService: CCUsagePricingService

    init(pricingService: CCUsagePricingService = .shared) {
        self.pricingService = pricingService
    }

    typealias Snapshot = LocalUsageSnapshot

    enum ServiceError: LocalizedError {
        case bundledExecutableMissing
        case helperTimedOut
        case invalidOutput
        case helperFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledExecutableMissing:
                return "TokenRemain 安装不完整：缺少内置 ccusage 组件。请重新安装最新版。"
            case .helperTimedOut:
                return "内置 ccusage 读取超时。请先重试；若持续失败，请重新安装最新版 TokenRemain。"
            case .invalidOutput:
                return "内置 ccusage 返回了无法识别的数据。请重试或重新安装最新版 TokenRemain。"
            case .helperFailed(let detail):
                return "内置 ccusage 无法读取本机日志：\(detail)"
            }
        }
    }

    func fetch() async throws -> DailyUsage {
        try await fetchSnapshot(days: 1).daily
    }

    func fetchHistory(days: Int = 30, now: Date = .now) async throws -> DailyUsageHistory {
        try await fetchSnapshot(days: days, now: now).history
    }

    /// Reads today's totals and multi-day history from one invocation of the
    /// bundled native ccusage helper. Public prices are refreshed separately
    /// on a fixed daily cadence; `--offline` guarantees that the helper itself
    /// never sends local usage-derived data to a pricing or package service.
    func fetchSnapshot(days: Int = 30, now: Date = .now) async throws -> Snapshot {
        try await run(prepareInvocation(days: days, now: now), now: now)
    }

    /// Everything the helper's output depends on besides the agent logs it
    /// reads, resolved without launching it.
    struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let claudeDirectories: [URL]
        let pricingConfigurationURL: URL?
    }

    func prepareInvocation(days: Int = 30, now: Date = .now) async throws -> Invocation {
        let start = Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: now) ?? now
        let since = Self.dateFormatter.string(from: start)
        let executable = Self.bundledExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ServiceError.bundledExecutableMissing
        }
        let directories = try await Self.claudeLogDirectories()
        var environment = ProcessInfo.processInfo.environment
        if !directories.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = directories.map(\.path).joined(separator: ",")
        }
        let pricingConfigurationURL = await pricingService.configurationURL(now: now)
        return Invocation(
            executable: executable,
            arguments: Self.commandArguments(
                since: since,
                pricingConfigurationURL: pricingConfigurationURL
            ),
            environment: environment,
            claudeDirectories: directories,
            pricingConfigurationURL: pricingConfigurationURL
        )
    }

    func run(_ invocation: Invocation, now: Date = .now) async throws -> Snapshot {
        Self.snapshot(
            from: try await runReport(invocation, environment: invocation.environment),
            now: now
        )
    }

    /// One helper run with the given environment, decoded but not yet turned
    /// into a snapshot, so separately run halves can be merged first.
    func runReport(_ invocation: Invocation, environment: [String: String]) async throws -> Report {
        let data: Data
        do {
            data = try await ProcessRunner.run(
                invocation.executable.path,
                arguments: invocation.arguments,
                environment: environment,
                timeout: 30
            )
        } catch let error as URLError where error.code == .timedOut {
            throw ServiceError.helperTimedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ServiceError.helperFailed(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(Report.self, from: data)
        } catch {
            throw ServiceError.invalidOutput
        }
    }

    // MARK: - Codex split

    /// Codex costs about 90% of a run: the helper rereads every Codex session,
    /// gigabytes on a busy Mac, whatever `--since` says, while all other
    /// agents together cost about a tenth of that. The same unified report run
    /// twice, with the agents separated through their data directories, lets
    /// an unchanged Codex half be reused; the halves merge to the full report.
    struct SplitEnvironments: Sendable {
        /// Every agent except Codex.
        let others: [String: String]
        /// Codex alone: no home directory means no other agent's defaults.
        let codex: [String: String]
    }

    static let codexAgentID = "codex"
    static let isolationDirectory = URL(fileURLWithPath: "/var/empty", isDirectory: true)

    /// Nil when no guaranteed-empty directory exists; callers then run the
    /// full report as before.
    static func splitEnvironments(
        for invocation: Invocation,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isolationDirectory: URL = isolationDirectory,
        fileManager: FileManager = .default
    ) -> SplitEnvironments? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: isolationDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? fileManager.contentsOfDirectory(atPath: isolationDirectory.path))?.isEmpty == true
        else { return nil }
        let empty = isolationDirectory.path
        var others = invocation.environment
        others["CODEX_HOME"] = empty
        var codex = ["HOME": empty]
        codex["CODEX_HOME"] = invocation.environment["CODEX_HOME"]
            ?? home.appending(path: ".codex", directoryHint: .isDirectory).path
        for key in ["PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] {
            codex[key] = invocation.environment[key]
        }
        return SplitEnvironments(others: others, codex: codex)
    }

    /// Codex entries come only from the Codex half and every other agent only
    /// from the other half, so a change in how the helper discovers agents can
    /// never count one twice. Codex keeps its place right after Claude, as in
    /// the unified report.
    static func merged(others: Report, codex: Report) -> Report {
        func isCodex(_ agent: Report.Agent) -> Bool {
            agent.agent.caseInsensitiveCompare(codexAgentID) == .orderedSame
        }
        var agentsByPeriod: [String: [Report.Agent]] = [:]
        for row in others.daily {
            agentsByPeriod[row.period, default: []] += (row.agents ?? []).filter { !isCodex($0) }
        }
        for row in codex.daily {
            let codexAgents = (row.agents ?? []).filter(isCodex)
            var agents = agentsByPeriod[row.period, default: []]
            let index = agents.prefix { $0.agent.caseInsensitiveCompare("claude") == .orderedSame }.count
            agents.insert(contentsOf: codexAgents, at: index)
            agentsByPeriod[row.period] = agents
        }
        return Report(daily: agentsByPeriod.keys.sorted().map { period in
            Report.Row(period: period, agents: agentsByPeriod[period])
        })
    }

    /// A desktop scan that hits its entry limit or deadline must not take the
    /// default, environment and user-added directories down with it. Data
    /// Sources reports the incomplete scan on its own.
    static func claudeLogDirectories(
        timeout: TimeInterval = 5,
        discover: @escaping @Sendable (_ scanDesktopSessions: Bool) throws -> [URL] = {
            try ClaudeLogDirectories.discover(scanDesktopSessions: $0)
        }
    ) async throws -> [URL] {
        do {
            return try await AsyncDeadline.run(timeout: timeout) { try discover(true) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (try? discover(false)) ?? []
        }
    }

    static func commandArguments(
        since: String,
        timeZone: TimeZone = .current,
        pricingConfigurationURL: URL? = nil
    ) -> [String] {
        var arguments = [
            "daily",
            "--json",
            "--by-agent",
            "--offline",
            "--no-color",
            "--timezone", timeZone.identifier,
            "--since", since
        ]
        if let pricingConfigurationURL {
            arguments.append(contentsOf: ["--config", pricingConfigurationURL.path])
        }
        return arguments
    }

    static func bundledExecutableURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ccusage", isDirectory: false)
    }

    static func parseSnapshot(_ data: Data, now: Date = .now) throws -> Snapshot {
        snapshot(from: try JSONDecoder().decode(Report.self, from: data), now: now)
    }

    static func snapshot(from payload: Report, now: Date = .now) -> Snapshot {
        let today = dateFormatter.string(from: now)
        let row = payload.daily.first(where: { $0.period == today })
        let agents = (row?.agents ?? []).map {
            DailyUsage.Agent(
                id: $0.agent,
                tokens: $0.totalTokens,
                estimatedCost: $0.totalCost,
                unpricedModels: unpricedModels(in: $0)
            )
        }
        return Snapshot(
            daily: DailyUsage(
                date: row?.period ?? today,
                agents: agents,
                capturedAt: now
            ),
            history: parseHistory(payload, now: now)
        )
    }

    /// Decodes a ccusage `daily --by-agent --json` payload into a stacked-per-day
    /// history. Split out from the fetch so it is exercised by unit tests without
    /// shelling out. Days are returned oldest-first and every detected agent is
    /// retained; the UI chooses which series are visible.
    static func parseHistory(_ data: Data, now: Date = .now) throws -> DailyUsageHistory {
        let payload = try JSONDecoder().decode(Report.self, from: data)
        return parseHistory(payload, now: now)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Parses a ccusage `period` (`yyyy-MM-dd`) to local midnight so month/day
    /// axis labels and the day-of-week read in the user's own calendar.
    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// A decoded `daily --by-agent --json` payload. Only per-agent entries are
    /// read; row totals are never used.
    struct Report: Decodable, Sendable, Equatable {
        let daily: [Row]

        struct Row: Decodable, Sendable, Equatable {
            let period: String
            let agents: [Agent]?
        }
        struct Agent: Decodable, Sendable, Equatable {
            let agent: String
            let totalTokens: Int64
            let totalCost: Double
            let modelsUsed: [String]?
            let modelBreakdowns: [ModelBreakdown]?
        }
        struct ModelBreakdown: Decodable, Sendable, Equatable {
            let modelName: String
            let cost: Double
            let inputTokens: Int64
            let outputTokens: Int64
            let cacheCreationTokens: Int64
            let cacheReadTokens: Int64

            var totalTokens: Int64 {
                inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
            }
        }
    }

    private static func unpricedModels(in agent: Report.Agent) -> [String] {
        // Ollama is intentionally local and has no API list price. For hosted
        // agents, a model row with tokens and a zero cost is indistinguishable
        // from a missing price in ccusage, so present it as unavailable rather
        // than claiming the usage was free.
        guard agent.agent.caseInsensitiveCompare("ollama") != .orderedSame else { return [] }
        let rows = agent.modelBreakdowns ?? []
        let missing = rows
            .filter { $0.totalTokens > 0 && $0.cost == 0 && $0.modelName != "<synthetic>" }
            .map(\.modelName)
        if !missing.isEmpty {
            return Array(Set(missing)).sorted()
        }
        if agent.totalTokens > 0, agent.totalCost == 0, rows.isEmpty {
            return Array(Set(agent.modelsUsed ?? [])).sorted()
        }
        return []
    }

    private static func parseHistory(
        _ payload: Report,
        now: Date
    ) -> DailyUsageHistory {
        let days = payload.daily.compactMap { row -> DailyUsageHistory.Day? in
            guard let date = periodFormatter.date(from: row.period) else { return nil }
            return DailyUsageHistory.Day(
                date: date,
                agents: (row.agents ?? []).map {
                    DailyUsageHistory.Agent(
                        id: $0.agent.lowercased(),
                        tokens: $0.totalTokens,
                        cost: $0.totalCost,
                        unpricedModels: unpricedModels(in: $0),
                        models: historyModels(in: $0)
                    )
                }
            )
        }
        .sorted { $0.date < $1.date }
        return DailyUsageHistory(days: days, capturedAt: now)
    }

    private static func historyModels(in agent: Report.Agent) -> [DailyUsageHistory.ModelUsage] {
        DailyUsageHistory.boundedModels((agent.modelBreakdowns ?? []).map { row in
            DailyUsageHistory.ModelUsage(
                id: row.modelName,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheTokens: row.cacheCreationTokens + row.cacheReadTokens,
                cost: row.cost,
                cacheWriteTokens: row.cacheCreationTokens,
                cacheReadTokens: row.cacheReadTokens
            )
        })
    }
}
