import Foundation

/// Currencies the Dashboard can show estimated costs in. Every estimate is
/// computed in USD (API list prices); other currencies are a display-time
/// conversion, never a different price source.
enum DisplayCurrency: String, CaseIterable, Identifiable, Codable, Sendable {
    case usd = "USD"
    case cny = "CNY"
    case eur = "EUR"
    case jpy = "JPY"
    case gbp = "GBP"
    case hkd = "HKD"
    case twd = "TWD"
    case krw = "KRW"
    case aud = "AUD"
    case cad = "CAD"
    case sgd = "SGD"
    case chf = "CHF"
    case inr = "INR"

    var id: String { rawValue }

    /// ISO 4217 minor units for the two zero-decimal currencies; the rest keep
    /// cents so small daily estimates do not round to zero.
    var fractionDigits: Int {
        switch self {
        case .jpy, .krw: 0
        default: 2
        }
    }

    func localizedName(locale: Locale = .current) -> String {
        locale.localizedString(forCurrencyCode: rawValue) ?? rawValue
    }

    /// USD keeps the bare `$` the app has always shown. Other symbols follow
    /// the user's locale (e.g. `CN¥` vs `¥`) so CNY and JPY never collide.
    func symbol(locale: Locale = .current) -> String {
        if self == .usd { return "$" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = rawValue
        let symbol = formatter.currencySymbol ?? rawValue
        return symbol.isEmpty ? rawValue : symbol
    }
}

/// A selected currency plus the USD rate in effect. Views format through this
/// value so a cost and its axis, tooltip and accessibility label always use
/// the same rate.
struct CurrencyDisplay: Equatable, Sendable {
    let currency: DisplayCurrency
    /// Units of `currency` per 1 USD.
    let rate: Double
    let symbol: String

    static let usd = CurrencyDisplay(currency: .usd, rate: 1)

    init(currency: DisplayCurrency, rate: Double, locale: Locale? = nil) {
        self.currency = currency
        self.rate = rate.isFinite && rate > 0 ? rate : 1
        symbol = locale.map { currency.symbol(locale: $0) } ?? Self.currentSymbols[currency] ?? currency.rawValue
    }

    /// Resolved once: views rebuild `CurrencyDisplay` on every render.
    private static let currentSymbols: [DisplayCurrency: String] = Dictionary(
        uniqueKeysWithValues: DisplayCurrency.allCases.map { ($0, $0.symbol()) }
    )
    private static let groupedFormatters: [Int: NumberFormatter] = Dictionary(
        uniqueKeysWithValues: [0, 2].map { digits in
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            return (digits, formatter)
        }
    )

    var isUSD: Bool { currency == .usd }

    func convert(_ usd: Double) -> Double { usd * rate }

    /// Full-precision amount, e.g. `$120.33`, `CN¥857.10`, `₩171,234`.
    func amount(usd: Double) -> String {
        formatConverted(convert(usd))
    }

    /// Popover style: USD keeps the locale-aware `L10n.usd` output it always had.
    func localizedAmount(usd: Double) -> String {
        isUSD ? L10n.usd(usd) : amount(usd: usd)
    }

    func formatConverted(_ value: Double) -> String {
        if isUSD { return String(format: "$%.2f", value) }
        return symbol + Self.grouped(value, fractionDigits: currency.fractionDigits)
    }

    /// Short tile form: below 1K the full amount, above it `K` / `M`.
    func compact(usd: Double) -> String {
        compactConverted(convert(usd))
    }

    func compactConverted(_ value: Double) -> String {
        if value >= 1_000_000 { return symbol + String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return symbol + String(format: "%.1fK", value / 1_000) }
        return formatConverted(value)
    }

    /// Narrow y-axis label for an already converted value. USD keeps its
    /// historical `$250` form; other symbols are wider (`CN¥`, `HK$`), so they
    /// switch to `K` / `M` from 1,000 to fit the chart gutter.
    func axisLabel(_ value: Double) -> String {
        if isUSD {
            return value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.1f", value)
        }
        for (threshold, suffix) in [(1_000_000.0, "M"), (1_000.0, "K")] where value >= threshold {
            let scaled = value / threshold
            let text = scaled.rounded() == scaled || scaled >= 100
                ? String(format: "%.0f", scaled)
                : String(format: "%.1f", scaled)
            return symbol + text + suffix
        }
        if value >= 100 || currency.fractionDigits == 0 {
            return symbol + String(format: "%.0f", value)
        }
        return symbol + String(format: "%.1f", value)
    }

    private static func grouped(_ value: Double, fractionDigits: Int) -> String {
        groupedFormatters[fractionDigits]?.string(from: NSNumber(value: value))
            ?? String(format: "%.\(fractionDigits)f", value)
    }
}
