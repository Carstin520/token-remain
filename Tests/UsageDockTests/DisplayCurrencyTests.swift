import Foundation
import Testing
@testable import UsageDock

@Suite("Display currency")
struct DisplayCurrencyTests {
    private let english = Locale(identifier: "en_US")

    @Test("USD keeps the exact strings the app has always shown")
    func usdUnchanged() {
        let usd = CurrencyDisplay.usd
        #expect(usd.amount(usd: 120.333) == "$120.33")
        #expect(usd.compact(usd: 2_500) == "$2.5K")
        #expect(usd.axisLabel(250) == "$250")
        #expect(usd.axisLabel(62.5) == "$62.5")
    }

    @Test("Other currencies convert and use their own minor units")
    func convertsWithMinorUnits() {
        let cny = CurrencyDisplay(currency: .cny, rate: 7.1, locale: english)
        #expect(cny.amount(usd: 10) == "\(cny.symbol)71.00")

        let krw = CurrencyDisplay(currency: .krw, rate: 1_400, locale: english)
        #expect(krw.symbol == "₩")
        #expect(krw.amount(usd: 120.33).hasSuffix("168,462"))
        #expect(krw.axisLabel(250_000) == "₩250K")
        let cnyAxis = CurrencyDisplay(currency: .cny, rate: 7.1, locale: english)
        #expect(cnyAxis.axisLabel(1_500) == "\(cnyAxis.symbol)1.5K")
        #expect(cnyAxis.axisLabel(2_000) == "\(cnyAxis.symbol)2K")
        #expect(cnyAxis.axisLabel(500) == "\(cnyAxis.symbol)500")

        let jpy = CurrencyDisplay(currency: .jpy, rate: 150, locale: english)
        #expect(jpy.axisLabel(75) == "\(jpy.symbol)75")
    }

    @Test("CNY and JPY never share a bare yen symbol in one locale")
    func yenSymbolsDiffer() {
        for identifier in ["en_US", "zh_CN", "ja_JP"] {
            let locale = Locale(identifier: identifier)
            #expect(DisplayCurrency.cny.symbol(locale: locale) != DisplayCurrency.jpy.symbol(locale: locale))
        }
    }

    @Test("Rates parse only for supported currencies within sane bounds")
    func parsesRates() throws {
        let data = Data("""
        {"result":"success","base_code":"USD","time_last_update_unix":1791849601,
         "rates":{"USD":1,"CNY":7.12,"JPY":149.8,"TWD":32.4,"EUR":-1,"XYZ":3,"KRW":1e9}}
        """.utf8)
        let rates = try ExchangeRateService.parse(data, fetchedAt: Date(timeIntervalSince1970: 0))
        #expect(rates.rate(for: .cny) == 7.12)
        #expect(rates.rate(for: .twd) == 32.4)
        #expect(rates.rate(for: .usd) == 1)
        #expect(rates.rate(for: .eur) == nil)
        #expect(rates.rate(for: .krw) == nil)
        #expect(rates.rates["XYZ"] == nil)
        #expect(rates.publishedAt == Date(timeIntervalSince1970: 1_791_849_601))
    }

    @Test("Error payloads and foreign bases are rejected")
    func rejectsBadPayloads() {
        let failed = Data(#"{"result":"error","error-type":"unsupported-code"}"#.utf8)
        #expect(throws: ExchangeRateService.RateError.self) {
            try ExchangeRateService.parse(failed, fetchedAt: .now)
        }
        let euroBase = Data(#"{"result":"success","base_code":"EUR","rates":{"CNY":7.7}}"#.utf8)
        #expect(throws: ExchangeRateService.RateError.self) {
            try ExchangeRateService.parse(euroBase, fetchedAt: .now)
        }
    }

    @Test("A successful fetch is cached; failures and rapid retries leave it intact")
    func fetchCachesAndThrottles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rates-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data(#"{"result":"success","base_code":"USD","rates":{"CNY":7.2}}"#.utf8)
        let service = ExchangeRateService(cacheDirectory: directory) { request in
            #expect(request.url == ExchangeRateService.sourceURL)
            #expect(request.httpBody == nil)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let now = Date()
        let rates = try await service.fetch(now: now, manual: true)
        #expect(rates.rate(for: .cny) == 7.2)
        #expect(service.cachedRates() == rates)
        #expect(ExchangeRateService.isFresh(rates, now: now.addingTimeInterval(60)))
        #expect(!ExchangeRateService.isFresh(rates, now: now.addingTimeInterval(13 * 3_600)))

        await #expect(throws: ExchangeRateService.RateError.throttled) {
            try await service.fetch(now: now.addingTimeInterval(5), manual: true)
        }
        await #expect(throws: ExchangeRateService.RateError.throttled) {
            try await service.fetch(now: now.addingTimeInterval(60), manual: false)
        }
        #expect(service.cachedRates() == rates)
    }

    @Test("Without a usable rate the store falls back to USD instead of mislabeling")
    @MainActor
    func storeFallsBackToUSD() throws {
        let suite = "currency-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("EUR", forKey: CurrencyStore.selectionKey)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rates-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ExchangeRateService(cacheDirectory: directory) { _ in
            throw URLError(.notConnectedToInternet)
        }
        let store = CurrencyStore(defaults: defaults, service: service)
        #expect(store.selected == .eur)
        #expect(store.isFallingBackToUSD)
        #expect(store.display == .usd)
    }
}

/// Counts requests and fails the first `failures` of them.
private final class RateStub: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failures: Int

    init(failures: Int) { self.failures = failures }

    var requests: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.lock()
        count += 1
        let attempt = count
        lock.unlock()
        if attempt <= failures { throw URLError(.notConnectedToInternet) }
        let body = Data(#"{"result":"success","base_code":"USD","rates":{"CNY":7.2}}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Display currency refresh")
@MainActor
struct CurrencyRefreshTests {
    private func settle(_ store: CurrencyStore) async {
        for _ in 0..<200 where store.status == .loading {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("Automatic checks retry a failed first request after the back-off, not before")
    func retriesAfterBackoff() async throws {
        let suite = "currency-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("CNY", forKey: CurrencyStore.selectionKey)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rates-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = RateStub(failures: 1)
        let service = ExchangeRateService(cacheDirectory: directory) { try stub.respond($0) }

        // init makes the first automatic attempt, which fails.
        let store = CurrencyStore(defaults: defaults, service: service)
        await settle(store)
        #expect(stub.requests == 1)
        #expect(store.isFallingBackToUSD)

        // Frequent refresh calls inside the back-off do not hit the network.
        let start = Date()
        for minute in 1...29 {
            store.refreshIfStale(now: start.addingTimeInterval(Double(minute) * 60))
            await settle(store)
        }
        #expect(stub.requests == 1)

        store.refreshIfStale(now: start.addingTimeInterval(31 * 60))
        await settle(store)
        #expect(stub.requests == 2)
        #expect(store.display.currency == .cny)
        #expect(store.status == .idle)
    }

    @Test("An expired table is refreshed by the next automatic check")
    func refreshesExpiredRates() async throws {
        let suite = "currency-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("CNY", forKey: CurrencyStore.selectionKey)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rates-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = RateStub(failures: 0)
        let service = ExchangeRateService(cacheDirectory: directory) { try stub.respond($0) }

        let store = CurrencyStore(defaults: defaults, service: service)
        await settle(store)
        #expect(stub.requests == 1)
        let fetchedAt = try #require(store.rates?.fetchedAt)

        store.refreshIfStale(now: fetchedAt.addingTimeInterval(60))
        await settle(store)
        #expect(stub.requests == 1)

        store.refreshIfStale(now: fetchedAt.addingTimeInterval(13 * 3_600))
        await settle(store)
        #expect(stub.requests == 2)
    }
}
