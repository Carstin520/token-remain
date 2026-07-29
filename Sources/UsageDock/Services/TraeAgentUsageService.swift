import Foundation

/// Reads Trae Agent's opt-in trajectory JSON files without decoding prompts,
/// messages, tool arguments, code, or responses. Only the model identity,
/// timestamp, and aggregate token counters are represented by the Decodable
/// allowlist below.
struct TraeAgentUsageService {
    static let agentID = "trae-agent"
    static let maximumFiles = 5_000
    static let maximumFileBytes = 32 * 1024 * 1024
    static let maximumTokensPerCounter: Int64 = 1_000_000_000_000

    private let directories: [URL]
    private let pricingService: CCUsagePricingService
    private let fileManager: FileManager

    init(
        directories: [URL],
        pricingService: CCUsagePricingService = .shared,
        fileManager: FileManager = .default
    ) {
        self.directories = directories
        self.pricingService = pricingService
        self.fileManager = fileManager
    }

    func fetchSnapshot(days: Int = 30, now: Date = .now) async -> LocalUsageSnapshot {
        let prices = await pricingService.pricingSnapshot(now: now)
        let files = Self.trajectoryFiles(
            in: directories,
            fileManager: fileManager
        ).compactMap { url -> (URL, Data)? in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.intValue >= 0,
                  size.intValue <= Self.maximumFileBytes,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                return nil
            }
            return (url, data)
        }
        return Self.parse(
            files: files,
            pricingOverrides: prices,
            days: days,
            now: now
        )
    }

    static func parse(
        files: [(URL, Data)],
        pricingOverrides: [String: CCUsagePricingService.PricingOverride],
        days: Int = 30,
        now: Date = .now,
        calendar inputCalendar: Calendar = .current
    ) -> LocalUsageSnapshot {
        let calendar = inputCalendar
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(
            byAdding: .day,
            value: -(max(1, days) - 1),
            to: today
        ) ?? today
        var totals: [Date: Totals] = [:]
        var seenFiles = Set<String>()
        let decoder = JSONDecoder()

        for (url, data) in files {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seenFiles.insert(path).inserted,
                  data.count <= maximumFileBytes,
                  let trajectory = try? decoder.decode(Trajectory.self, from: data) else {
                continue
            }
            for interaction in trajectory.llmInteractions ?? [] {
                guard let timestamp = parseTimestamp(interaction.timestamp),
                      timestamp >= earliest,
                      timestamp < calendar.date(byAdding: .day, value: 1, to: today) ?? .distantFuture,
                      let usage = interaction.response?.usage,
                      usage.totalTokens > 0 else {
                    continue
                }
                let day = calendar.startOfDay(for: timestamp)
                let provider = sanitizedIdentifier(
                    interaction.provider ?? trajectory.provider,
                    maximumLength: 128
                )
                let model = sanitizedIdentifier(
                    interaction.model ?? trajectory.model,
                    maximumLength: 512
                )
                let localOnly = isLocalProvider(provider)
                let match = model.flatMap {
                    CCUsagePricingService.matchedPricing(
                        modelName: $0,
                        provider: provider,
                        pricingOverrides: pricingOverrides
                    )
                }
                let cost = match?.price.estimatedCost(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    cacheCreationTokens: usage.cacheCreationInputTokens,
                    cacheReadTokens: usage.cacheReadInputTokens
                ) ?? 0
                let missingModel: String? = {
                    guard !localOnly, match == nil else { return nil }
                    return model?.isEmpty == false ? model : "<unknown-model>"
                }()
                totals[day, default: Totals()].add(
                    tokens: usage.totalTokens,
                    cost: cost,
                    unpricedModel: missingModel
                )
            }
        }

        let capturedAt = now
        let historyDays = totals.keys.sorted().map { day in
            let value = totals[day] ?? Totals()
            return DailyUsageHistory.Day(
                date: day,
                agents: [DailyUsageHistory.Agent(
                    id: agentID,
                    tokens: value.tokens,
                    cost: value.cost,
                    unpricedModels: value.unpricedModels.sorted()
                )]
            )
        }
        let todayTotals = totals[today]
        return LocalUsageSnapshot(
            daily: DailyUsage(
                date: dayFormatter.string(from: today),
                agents: todayTotals.map { value in
                    [DailyUsage.Agent(
                        id: agentID,
                        tokens: value.tokens,
                        estimatedCost: value.cost,
                        unpricedModels: value.unpricedModels.sorted()
                    )]
                } ?? [],
                capturedAt: capturedAt
            ),
            history: DailyUsageHistory(days: historyDays, capturedAt: capturedAt)
        )
    }

    static func trajectoryFiles(
        in directories: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for directory in directories {
            guard result.count < maximumFiles else { break }
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(root.path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                continue
            }
            if !isDirectory.boolValue {
                if root.pathExtension.caseInsensitiveCompare("json") == .orderedSame {
                    result.append(root)
                }
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL, result.count < maximumFiles {
                guard url.pathExtension.caseInsensitiveCompare("json") == .orderedSame,
                      let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                if seen.insert(canonical.path).inserted {
                    result.append(canonical)
                }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private struct Trajectory: Decodable {
        let provider: String?
        let model: String?
        let llmInteractions: [Interaction]?

        enum CodingKeys: String, CodingKey {
            case provider
            case model
            case llmInteractions = "llm_interactions"
        }
    }

    private struct Interaction: Decodable {
        let timestamp: String?
        let provider: String?
        let model: String?
        let response: Response?
    }

    private struct Response: Decodable {
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheCreationInputTokens: Int64
        let cacheReadInputTokens: Int64

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = min(maximumTokensPerCounter, max(
                0,
                try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
            ))
            outputTokens = min(maximumTokensPerCounter, max(
                0,
                try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
            ))
            cacheCreationInputTokens = min(maximumTokensPerCounter, max(
                0,
                try container.decodeIfPresent(Int64.self, forKey: .cacheCreationInputTokens) ?? 0
            ))
            cacheReadInputTokens = min(maximumTokensPerCounter, max(
                0,
                try container.decodeIfPresent(Int64.self, forKey: .cacheReadInputTokens) ?? 0
            ))
        }

        var totalTokens: Int64 {
            inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
        }
    }

    private struct Totals {
        var tokens: Int64 = 0
        var cost: Double = 0
        var unpricedModels = Set<String>()

        mutating func add(tokens: Int64, cost: Double, unpricedModel: String?) {
            let addition = max(0, tokens)
            self.tokens = addition > Int64.max - self.tokens
                ? Int64.max
                : self.tokens + addition
            self.cost += max(0, cost)
            if let unpricedModel { unpricedModels.insert(unpricedModel) }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func isLocalProvider(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.lowercased()
        return normalized.contains("ollama")
            || normalized.contains("lmstudio")
            || normalized.contains("lm-studio")
            || normalized == "local"
    }

    private static func sanitizedIdentifier(
        _ value: String?,
        maximumLength: Int
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scalars = trimmed.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars)).prefix(maximumLength)
        return sanitized.isEmpty ? nil : String(sanitized)
    }
}

/// Persists only user-selected local directory paths. Trajectory contents are
/// never copied into preferences. Two conventional Trae Agent output roots are
/// detected automatically when they exist.
struct TraeAgentTrajectoryStore {
    static let defaultsKey = "tokenRemain.traeAgentTrajectoryDirectories.v1"

    private let defaults: UserDefaults
    private let home: URL
    private let fileManager: FileManager

    init(
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.home = home
        self.fileManager = fileManager
    }

    var configuredDirectories: [URL] {
        normalized(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    var availableDirectories: [URL] {
        let automatic = [
            home.appending(path: "trajectories", directoryHint: .isDirectory),
            home.appending(path: ".trae-agent/trajectories", directoryHint: .isDirectory)
        ].filter { fileManager.fileExists(atPath: $0.path) }
        return unique(automatic + configuredDirectories)
    }

    func add(_ url: URL) {
        let values = unique(configuredDirectories + [url]).map(\.path)
        defaults.set(values, forKey: Self.defaultsKey)
    }

    func remove(_ url: URL) {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let values = configuredDirectories
            .filter { $0.standardizedFileURL.resolvingSymlinksInPath().path != target }
            .map(\.path)
        defaults.set(values, forKey: Self.defaultsKey)
    }

    private func normalized(_ values: [String]) -> [URL] {
        unique(values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    private func unique(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.compactMap { value in
            let url = value.standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(url.path).inserted ? url : nil
        }
        .sorted { $0.path < $1.path }
    }
}
