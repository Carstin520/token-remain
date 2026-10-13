import Foundation

/// The user's display currency and the rate used to convert USD estimates.
///
/// Waiting design: a rate refresh never blocks a cost from rendering. While a
/// request is in flight the last good rate stays on screen; with no usable
/// rate at all, costs stay in USD and Settings says why. Requests are bounded
/// by the URLSession timeouts (10 s request / 12 s resource), deduplicated,
/// and a late result after switching back to USD is harmless because rates
/// are shared data, not per-selection state.
@MainActor
final class CurrencyStore: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case failed(String)
    }

    static let shared = CurrencyStore()
    static let selectionKey = "tokenRemain.displayCurrency.v1"

    @Published private(set) var selected: DisplayCurrency
    @Published private(set) var rates: ExchangeRates?
    @Published private(set) var status: Status = .idle

    private let defaults: UserDefaults
    private let service: ExchangeRateService
    private var refreshTask: Task<Void, Never>?
    /// Automatic checks arrive with every local-usage refresh; this keeps a
    /// failing or offline source to one attempt per back-off interval.
    private var lastAutomaticAttempt: Date?

    init(defaults: UserDefaults = .standard, service: ExchangeRateService = .shared) {
        self.defaults = defaults
        self.service = service
        selected = defaults.string(forKey: Self.selectionKey)
            .flatMap(DisplayCurrency.init(rawValue:)) ?? .usd
        rates = service.cachedRates()
        refreshIfStale()
    }

    /// What views format with. Falls back to USD rather than showing a
    /// currency symbol over an unconverted number.
    var display: CurrencyDisplay {
        guard selected != .usd, let rate = rates?.rate(for: selected) else { return .usd }
        return CurrencyDisplay(currency: selected, rate: rate)
    }

    var isFallingBackToUSD: Bool {
        selected != .usd && rates?.rate(for: selected) == nil
    }

    func select(_ currency: DisplayCurrency) {
        guard currency != selected else { return }
        selected = currency
        defaults.set(currency.rawValue, forKey: Self.selectionKey)
        if currency == .usd {
            if case .failed = status { status = .idle }
        } else if !ExchangeRateService.isFresh(rates, now: .now) {
            // Choosing a currency is an explicit action: it is not held back
            // by the automatic back-off, only by the short manual throttle.
            refresh(manual: true)
        }
    }

    /// Called on every local-usage refresh (background loop, menu-bar and
    /// floating-widget presentation, Dashboard), so a stale or missing rate is
    /// retried even when the Dashboard is never opened. A no-op for USD,
    /// while the table is fresh, or within the automatic back-off.
    func refreshIfStale(now: Date = .now) {
        guard selected != .usd,
              !ExchangeRateService.isFresh(rates, now: now) else { return }
        if let lastAutomaticAttempt {
            let since = now.timeIntervalSince(lastAutomaticAttempt)
            if since >= 0, since < ExchangeRateService.automaticRetryInterval { return }
        }
        lastAutomaticAttempt = now
        refresh(manual: false, now: now)
    }

    func refresh(manual: Bool = true, now: Date = .now) {
        guard refreshTask == nil else { return }
        status = .loading
        refreshTask = Task { @MainActor [weak self, service] in
            do {
                let updated = try await service.fetch(now: now, manual: manual)
                guard let self else { return }
                rates = updated
                status = .idle
            } catch ExchangeRateService.RateError.throttled where !manual {
                self?.status = .idle
            } catch is CancellationError {
                self?.status = .idle
            } catch {
                self?.status = .failed(Self.message(for: error))
            }
            self?.refreshTask = nil
        }
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
                ? L10n.text("currency.error_timeout")
                : L10n.text("currency.error_network")
        }
        return (error as? LocalizedError)?.errorDescription ?? L10n.text("currency.error_network")
    }
}
