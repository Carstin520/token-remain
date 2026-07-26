import Foundation

/// Refreshes public model prices on a restrained cadence while keeping local
/// usage processing offline. Requests always download the same complete public
/// table: no credential, model name, token count, project, or usage-derived
/// query parameter is ever attached.
actor CCUsagePricingService {
    typealias Fetcher = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    struct PricingOverride: Codable, Equatable, Sendable {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputTokenCost: Double?
        let cacheReadInputTokenCost: Double?
        let inputCostPerTokenAbove200kTokens: Double?
        let outputCostPerTokenAbove200kTokens: Double?
        let cacheCreationInputTokenCostAbove200kTokens: Double?
        let cacheReadInputTokenCostAbove200kTokens: Double?
        let maxInputTokens: Int?
        let fastMultiplier: Double?

        var isValid: Bool {
            Self.validCost(inputCostPerToken)
                && Self.validCost(outputCostPerToken)
                && Self.validOptionalCost(cacheCreationInputTokenCost)
                && Self.validOptionalCost(cacheReadInputTokenCost)
                && Self.validOptionalCost(inputCostPerTokenAbove200kTokens)
                && Self.validOptionalCost(outputCostPerTokenAbove200kTokens)
                && Self.validOptionalCost(cacheCreationInputTokenCostAbove200kTokens)
                && Self.validOptionalCost(cacheReadInputTokenCostAbove200kTokens)
                && maxInputTokens.map { (1...100_000_000).contains($0) } != false
                && fastMultiplier.map { $0.isFinite && (0...100).contains($0) } != false
        }

        private static func validCost(_ value: Double) -> Bool {
            value.isFinite && (0...1).contains(value)
        }

        private static func validOptionalCost(_ value: Double?) -> Bool {
            value.map(validCost) != false
        }
    }

    private struct StoredPricing: Codable, Sendable {
        let schemaVersion: Int
        var fetchedAt: Date
        var eTag: String?
        var lastModified: String?
        let pricingOverrides: [String: PricingOverride]
    }

    private struct LiteLLMPrice: Decodable {
        struct ProviderSpecificEntry: Decodable {
            let fast: Double?
        }

        let inputCostPerToken: Double?
        let outputCostPerToken: Double?
        let cacheCreationInputTokenCost: Double?
        let cacheReadInputTokenCost: Double?
        let inputCostPerTokenAbove200kTokens: Double?
        let outputCostPerTokenAbove200kTokens: Double?
        let cacheCreationInputTokenCostAbove200kTokens: Double?
        let cacheReadInputTokenCostAbove200kTokens: Double?
        let maxInputTokens: Int?
        let providerSpecificEntry: ProviderSpecificEntry?

        enum CodingKeys: String, CodingKey {
            case inputCostPerToken = "input_cost_per_token"
            case outputCostPerToken = "output_cost_per_token"
            case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
            case cacheReadInputTokenCost = "cache_read_input_token_cost"
            case inputCostPerTokenAbove200kTokens = "input_cost_per_token_above_200k_tokens"
            case outputCostPerTokenAbove200kTokens = "output_cost_per_token_above_200k_tokens"
            case cacheCreationInputTokenCostAbove200kTokens = "cache_creation_input_token_cost_above_200k_tokens"
            case cacheReadInputTokenCostAbove200kTokens = "cache_read_input_token_cost_above_200k_tokens"
            case maxInputTokens = "max_input_tokens"
            case providerSpecificEntry = "provider_specific_entry"
        }
    }

    enum PricingError: Error {
        case invalidResponse
        case invalidSource
        case responseTooLarge
        case invalidPricing
    }

    static let shared = CCUsagePricingService()
    static let sourceURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = refreshInterval
    static let maximumResponseBytes = 8 * 1024 * 1024
    static let minimumValidPriceCount = 100
    private static let cacheSchemaVersion = 1
    private static let maximumModelNameLength = 512
    private static let maximumPriceCount = 20_000
    private static let maximumUserConfigurationBytes = 1024 * 1024

    private let fetcher: Fetcher
    private let fileManager: FileManager
    private let cacheURL: URL
    private let attemptURL: URL
    private let runtimeConfigurationURL: URL
    private var didLoadCache = false
    private var storedPricing: StoredPricing?
    private var lastRefreshAttempt: Date?
    private var isRefreshing = false

    init(
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default,
        fetcher: Fetcher? = nil
    ) {
        self.fileManager = fileManager
        let directory = cacheDirectory ?? fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appending(path: "com.jamesli.usagedock", directoryHint: .isDirectory)
        cacheURL = directory.appending(path: "ccusage-public-pricing-v1.json")
        attemptURL = directory.appending(path: "ccusage-pricing-attempt-v1.json")
        runtimeConfigurationURL = directory.appending(path: "ccusage-runtime-config-v1.json")

        if let fetcher {
            self.fetcher = fetcher
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 12
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            self.fetcher = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw PricingError.invalidResponse
                }
                return (data, http)
            }
        }
    }

    /// Returns an app-owned ccusage config when a validated online price cache
    /// is available. A refresh failure deliberately returns the last good
    /// config (or nil), so the bundled helper can continue with its embedded
    /// price snapshot.
    func configurationURL(now: Date = .now) async -> URL? {
        loadCacheIfNeeded()
        await refreshIfNeeded(now: now)
        guard let storedPricing else { return nil }

        let userConfiguration = Self.discoverUserConfiguration(
            fileManager: fileManager,
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryPath: fileManager.currentDirectoryPath
        )
        guard let data = Self.mergedRuntimeConfiguration(
            pricingOverrides: storedPricing.pricingOverrides,
            userConfiguration: userConfiguration
        ) else {
            return nil
        }

        do {
            try writeIfChanged(data, to: runtimeConfigurationURL)
            return runtimeConfigurationURL
        } catch {
            return nil
        }
    }

    private func refreshIfNeeded(now: Date) async {
        if let storedPricing, Self.isFresh(storedPricing.fetchedAt, now: now) {
            return
        }
        if let lastRefreshAttempt,
           now.timeIntervalSince(lastRefreshAttempt) >= 0,
           now.timeIntervalSince(lastRefreshAttempt) < Self.retryInterval {
            return
        }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        // Persist the attempt before opening the connection so relaunching the
        // app cannot turn a failed public-price request into a tight retry loop.
        // If the local throttle cannot be stored, retain the offline fallback
        // instead of making an unbounded request.
        do {
            try saveAttempt(now)
            lastRefreshAttempt = now
        } catch {
            return
        }

        do {
            let request = Self.request(
                eTag: storedPricing?.eTag,
                lastModified: storedPricing?.lastModified
            )
            let (data, response) = try await fetcher(request)
            try Self.validate(response: response, data: data)

            if response.statusCode == 304 {
                guard var cached = storedPricing else { throw PricingError.invalidResponse }
                cached.fetchedAt = now
                cached.eTag = response.value(forHTTPHeaderField: "ETag") ?? cached.eTag
                cached.lastModified = response.value(forHTTPHeaderField: "Last-Modified")
                    ?? cached.lastModified
                try save(cached)
                storedPricing = cached
                return
            }

            let overrides = try Self.parsePricing(data)
            guard Self.isValidPriceSet(overrides) else { throw PricingError.invalidPricing }
            let updated = StoredPricing(
                schemaVersion: Self.cacheSchemaVersion,
                fetchedAt: now,
                eTag: response.value(forHTTPHeaderField: "ETag"),
                lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                pricingOverrides: overrides
            )
            try save(updated)
            storedPricing = updated
        } catch {
            // A pricing refresh is best-effort. Existing prices remain usable,
            // and a missing cache makes ccusage fall back to its signed,
            // embedded snapshot without delaying or failing local token reads.
        }
    }

    static func request(eTag: String? = nil, lastModified: String? = nil) -> URLRequest {
        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenRemain public-pricing-refresh", forHTTPHeaderField: "User-Agent")
        if let eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        return request
    }

    static func parsePricing(_ data: Data) throws -> [String: PricingOverride] {
        guard data.count <= maximumResponseBytes else { throw PricingError.responseTooLarge }
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingError.invalidPricing
        }
        guard raw.count <= maximumPriceCount else { throw PricingError.invalidPricing }

        var overrides: [String: PricingOverride] = [:]
        overrides.reserveCapacity(raw.count)
        let decoder = JSONDecoder()
        for (model, rawPrice) in raw {
            // LiteLLM's public table also contains documentation/example rows
            // such as `sample_spec`, whose fields intentionally use strings.
            // Decode each model independently so one non-price row cannot
            // invalidate the complete signed-in-app pricing fallback path.
            guard Self.isValidModelName(model),
                  JSONSerialization.isValidJSONObject(rawPrice),
                  let priceData = try? JSONSerialization.data(withJSONObject: rawPrice),
                  let price = try? decoder.decode(LiteLLMPrice.self, from: priceData),
                  let input = price.inputCostPerToken,
                  let output = price.outputCostPerToken else {
                continue
            }
            let value = PricingOverride(
                inputCostPerToken: input,
                outputCostPerToken: output,
                cacheCreationInputTokenCost: price.cacheCreationInputTokenCost,
                cacheReadInputTokenCost: price.cacheReadInputTokenCost,
                inputCostPerTokenAbove200kTokens: price.inputCostPerTokenAbove200kTokens,
                outputCostPerTokenAbove200kTokens: price.outputCostPerTokenAbove200kTokens,
                cacheCreationInputTokenCostAbove200kTokens: price.cacheCreationInputTokenCostAbove200kTokens,
                cacheReadInputTokenCostAbove200kTokens: price.cacheReadInputTokenCostAbove200kTokens,
                maxInputTokens: price.maxInputTokens,
                fastMultiplier: price.providerSpecificEntry?.fast
            )
            if value.isValid {
                overrides[model] = value
            }
        }
        return overrides
    }

    static func mergedRuntimeConfiguration(
        pricingOverrides: [String: PricingOverride],
        userConfiguration: Data?
    ) -> Data? {
        let publicData = try? JSONEncoder().encode(pricingOverrides)
        guard let publicData,
              let publicObject = try? JSONSerialization.jsonObject(with: publicData),
              var mergedOverrides = publicObject as? [String: Any] else {
            return nil
        }

        var root: [String: Any] = [:]
        if let userConfiguration,
           userConfiguration.count <= maximumUserConfigurationBytes,
           let userObject = try? JSONSerialization.jsonObject(with: userConfiguration),
           let userRoot = userObject as? [String: Any] {
            root = userRoot
        }

        var defaults = root["defaults"] as? [String: Any] ?? [:]
        if let userOverrides = defaults["pricingOverrides"] as? [String: Any] {
            for (model, userValue) in userOverrides {
                if var publicValue = mergedOverrides[model] as? [String: Any],
                   let userFields = userValue as? [String: Any] {
                    for (field, value) in userFields {
                        publicValue[field] = value
                    }
                    mergedOverrides[model] = publicValue
                } else {
                    mergedOverrides[model] = userValue
                }
            }
        }
        defaults["pricingOverrides"] = mergedOverrides
        root["defaults"] = defaults
        if root["$schema"] == nil {
            root["$schema"] = "https://ccusage.com/config-schema.json"
        }

        guard JSONSerialization.isValidJSONObject(root) else { return nil }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func isFresh(_ fetchedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= -5 * 60 && age < refreshInterval
    }

    private static func validate(response: HTTPURLResponse, data: Data) throws {
        guard response.url?.scheme == "https",
              response.url?.host == sourceURL.host,
              response.url?.path == sourceURL.path else {
            throw PricingError.invalidSource
        }
        guard response.statusCode == 200 || response.statusCode == 304 else {
            throw PricingError.invalidResponse
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length"),
           let count = Int(length), count > maximumResponseBytes {
            throw PricingError.responseTooLarge
        }
        guard data.count <= maximumResponseBytes else { throw PricingError.responseTooLarge }
    }

    private static func isValidPriceSet(_ values: [String: PricingOverride]) -> Bool {
        values.count >= minimumValidPriceCount
            && values.count <= maximumPriceCount
            && values["claude-opus-5"]?.isValid == true
            && values.keys.contains { $0.hasPrefix("gpt-") && values[$0]?.isValid == true }
    }

    private static func isValidModelName(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumModelNameLength
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func discoverUserConfiguration(
        fileManager: FileManager,
        environment: [String: String],
        currentDirectoryPath: String
    ) -> Data? {
        var candidates = [
            URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appending(path: ".ccusage/ccusage.json")
        ]
        if let configured = environment["CLAUDE_CONFIG_DIR"] {
            candidates.append(contentsOf: configured
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0, isDirectory: true).appending(path: "ccusage.json") })
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            candidates.append(home.appending(path: ".config/claude/ccusage.json"))
            candidates.append(home.appending(path: ".claude/ccusage.json"))
        }

        for candidate in candidates {
            guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                  let size = attributes[.size] as? NSNumber,
                  size.intValue <= maximumUserConfigurationBytes,
                  let data = try? Data(contentsOf: candidate),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  object is [String: Any] else {
                continue
            }
            return data
        }
        return nil
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true
        if let attemptData = try? Data(contentsOf: attemptURL),
           let attemptedAt = try? JSONDecoder().decode(Date.self, from: attemptData) {
            lastRefreshAttempt = attemptedAt
        }
        guard let data = try? Data(contentsOf: cacheURL),
              data.count <= Self.maximumResponseBytes,
              let cached = try? JSONDecoder().decode(StoredPricing.self, from: data),
              cached.schemaVersion == Self.cacheSchemaVersion,
              Self.isValidPriceSet(cached.pricingOverrides) else {
            storedPricing = nil
            return
        }
        storedPricing = cached
    }

    private func saveAttempt(_ value: Date) throws {
        try writeIfChanged(try JSONEncoder().encode(value), to: attemptURL)
    }

    private func save(_ value: StoredPricing) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try writeIfChanged(data, to: cacheURL)
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws {
        if (try? Data(contentsOf: url)) == data { return }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
