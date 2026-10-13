import Foundation

/// Daily USD reference rates for display-only cost conversion.
struct ExchangeRates: Codable, Equatable, Sendable {
    /// When TokenRemain stored this table.
    let fetchedAt: Date
    /// When the provider last published it, if reported.
    let publishedAt: Date?
    /// Units per 1 USD, limited to `DisplayCurrency` codes.
    let rates: [String: Double]

    func rate(for currency: DisplayCurrency) -> Double? {
        currency == .usd ? 1 : rates[currency.rawValue]
    }
}

/// Fetches public reference rates. The request is a fixed GET with no query,
/// cookie or credential, so nothing about the user's usage leaves the Mac;
/// it is made only while a non-USD currency is selected.
actor ExchangeRateService {
    typealias Fetcher = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    enum RateError: LocalizedError, Equatable {
        case invalidResponse
        case invalidRates
        case responseTooLarge
        case throttled

        var errorDescription: String? {
            switch self {
            case .invalidResponse, .invalidRates, .responseTooLarge:
                L10n.text("currency.error_invalid")
            case .throttled:
                L10n.text("currency.error_throttled")
            }
        }
    }

    static let shared = ExchangeRateService()
    /// ExchangeRate-API's open endpoint: no key, updated once a day. Its terms
    /// require attribution, which Settings shows next to the rate.
    static let sourceURL = URL(string: "https://open.er-api.com/v6/latest/USD")!
    static let attributionURL = URL(string: "https://www.exchangerate-api.com")!
    /// The source publishes daily; asking more often only adds traffic.
    static let freshInterval: TimeInterval = 12 * 60 * 60
    /// After a failure, automatic refreshes back off; a manual retry may go
    /// sooner but not in a tight loop.
    static let automaticRetryInterval: TimeInterval = 30 * 60
    static let manualRetryInterval: TimeInterval = 15
    static let maximumResponseBytes = 256 * 1024

    private let fetcher: Fetcher
    private let fileManager: FileManager
    private let cacheURL: URL
    private var lastAttempt: Date?

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
        cacheURL = directory.appending(path: "exchange-rates-v1.json")

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
                    throw RateError.invalidResponse
                }
                return (data, http)
            }
        }
    }

    nonisolated func cachedRates() -> ExchangeRates? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ExchangeRates.self, from: data)
    }

    static func isFresh(_ rates: ExchangeRates?, now: Date) -> Bool {
        guard let rates else { return false }
        let age = now.timeIntervalSince(rates.fetchedAt)
        return age >= 0 && age < freshInterval
    }

    /// Downloads a new table. Throws without touching the cache on any
    /// failure, so the caller keeps showing the last good rates.
    func fetch(now: Date = .now, manual: Bool) async throws -> ExchangeRates {
        if let lastAttempt {
            let since = now.timeIntervalSince(lastAttempt)
            let minimum = manual ? Self.manualRetryInterval : Self.automaticRetryInterval
            if since >= 0, since < minimum { throw RateError.throttled }
        }
        lastAttempt = now

        let (data, response) = try await fetcher(Self.request())
        guard (200..<300).contains(response.statusCode) else { throw RateError.invalidResponse }
        let rates = try Self.parse(data, fetchedAt: now)
        try Task.checkCancellation()
        save(rates)
        return rates
    }

    static func request() -> URLRequest {
        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenRemain exchange-rate-refresh", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> ExchangeRates {
        guard data.count <= maximumResponseBytes else { throw RateError.responseTooLarge }
        struct Payload: Decodable {
            let result: String?
            let base_code: String?
            let time_last_update_unix: Double?
            let rates: [String: Double]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.result == "success",
              payload.base_code == "USD",
              let raw = payload.rates else { throw RateError.invalidResponse }

        var rates: [String: Double] = [:]
        for currency in DisplayCurrency.allCases where currency != .usd {
            // Bounds reject a corrupt or hostile table without hard-coding
            // today's values: every listed currency trades within these.
            guard let value = raw[currency.rawValue],
                  value.isFinite,
                  (0.0001...100_000).contains(value) else { continue }
            rates[currency.rawValue] = value
        }
        guard !rates.isEmpty else { throw RateError.invalidRates }
        return ExchangeRates(
            fetchedAt: fetchedAt,
            publishedAt: payload.time_last_update_unix.map(Date.init(timeIntervalSince1970:)),
            rates: rates
        )
    }

    private func save(_ rates: ExchangeRates) {
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(rates).write(to: cacheURL, options: .atomic)
        } catch {
            // In-memory rates still apply for this session.
        }
    }
}
