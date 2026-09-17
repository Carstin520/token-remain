import CoreFoundation
import Foundation

/// App-owned configuration, saved only after the submitted Cookie is validated.
/// API keys from a host CLI are deliberately not accepted as console credentials.
struct AlibabaTokenPlanConfiguration: Codable, Sendable {
    enum Region: String, Codable, CaseIterable, Sendable {
        case china = "cn-beijing"
        case international = "ap-southeast-1"

        var origin: String {
            self == .china ? "https://bailian.console.aliyun.com" : "https://modelstudio.console.alibabacloud.com"
        }
        var personalOrigin: String {
            self == .china ? "https://bailian-cs.console.aliyun.com" : "https://bailian-singapore-cs.alibabacloud.com"
        }
        var displayName: String { L10n.text("alibaba.region.\(self == .china ? "china" : "international")") }
    }
    enum Edition: String, Codable, CaseIterable, Sendable {
        case team, personal
        var displayName: String { L10n.text("alibaba.edition.\(rawValue)") }
    }
    let region: Region
    let edition: Edition
    let cookie: String

    var dashboardURL: URL {
        URL(string: "\(region.origin)/\(region.rawValue)/?tab=plan#/efm/subscription/token-plan\(edition == .personal ? "/personal" : "")")!
    }

    func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    static func decode(_ value: String) throws -> Self {
        guard let config = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)) else {
            throw AlibabaTokenPlanError.invalidConfiguration
        }
        _ = try config.cookieValues()
        return config
    }

    func cookieValues() throws -> [String: String] {
        guard cookie.utf8.count <= 32_768,
              !cookie.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AlibabaTokenPlanError.invalidConfiguration
        }
        var values: [String: String] = [:]
        for pair in cookie.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw AlibabaTokenPlanError.invalidConfiguration }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }),
                  values[name] == nil else { throw AlibabaTokenPlanError.invalidConfiguration }
            values[name] = value
        }
        guard !(values["login_aliyunid_csrf"] ?? values["csrf"] ?? "").isEmpty else {
            throw AlibabaTokenPlanError.invalidConfiguration
        }
        return values
    }
}

enum AlibabaTokenPlanError: Error, LocalizedError {
    case invalidConfiguration, authentication, unavailable, invalidResponse, requestFailed, network
    var errorDescription: String? {
        let key: String = switch self {
        case .invalidConfiguration: "configuration"
        case .authentication: "authentication"
        case .unavailable: "unavailable"
        case .invalidResponse: "response"
        case .requestFailed: "request"
        case .network: "network"
        }
        return L10n.text("alibaba.error.\(key)")
    }
}

struct AlibabaTokenPlanUsageService: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    var transport: Transport = Self.network
    var timeout: TimeInterval = 30

    func fetch(configuration: String? = nil, now: Date = .now) async throws -> ProviderQuota {
        guard let raw = configuration ?? ProviderSecretStore(provider: .alibabaTokenPlan).load() else {
            throw ExtendedProviderError.notConfigured(.alibabaTokenPlan)
        }
        let config = try AlibabaTokenPlanConfiguration.decode(raw)
        return try await AsyncDeadline.run(timeout: timeout) {
            let values = try config.cookieValues()
            var secToken = values["sec_token"]
            if secToken == nil {
                var request = Self.baseRequest(url: config.dashboardURL, config: config)
                request.setValue("text/html", forHTTPHeaderField: "Accept")
                request.setValue("\(config.region.origin)/", forHTTPHeaderField: "Referer")
                request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
                request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
                request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
                // Some accounts support Cookie-only reads. A missing optional
                // nonce must not prevent that path, or swallow cancellation.
                if let data = try? await read(request) { secToken = Self.secToken(in: data) }
                try Task.checkCancellation()
            }
            let request = try Self.usageRequest(config, secToken: secToken)
            let data = try await read(request)
            try Task.checkCancellation()
            return try Self.parse(data, configuration: config, now: now)
        }
    }

    private func read(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            switch response.statusCode {
            case 200..<300: break
            case 300..<400, 401: throw AlibabaTokenPlanError.authentication
            case 403: throw AlibabaTokenPlanError.requestFailed
            default: throw AlibabaTokenPlanError.requestFailed
            }
            guard data.count <= 2 * 1024 * 1024 else { throw AlibabaTokenPlanError.invalidResponse }
            return data
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw AsyncDeadline.Failure.timedOut }
            throw AlibabaTokenPlanError.network
        }
    }

    static func baseRequest(url: URL, config: AlibabaTokenPlanConfiguration) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpShouldHandleCookies = false
        request.setValue(config.cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func usageRequest(_ config: AlibabaTokenPlanConfiguration, secToken: String?) throws -> URLRequest {
        let values = try config.cookieValues()
        let personal = config.edition == .personal
        let action = personal
            ? (config.region == .china ? "BroadScopeAspnGateway" : "IntlBroadScopeAspnGateway")
            : "GetSubscriptionSummary"
        let product = personal ? "sfm_bailian" : "BssOpenAPI-V3"
        let api = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
        var url = URLComponents(string: personal ? config.region.personalOrigin : config.region.origin)!
        url.path = "/data/api.json"
        url.queryItems = [URLQueryItem(name: "action", value: action), URLQueryItem(name: "product", value: product)]
        if personal { url.queryItems?.append(URLQueryItem(name: "api", value: api)) }
        let params: [String: Any]
        if personal {
            params = ["Api": api, "V": "1.0", "Data": ["cornerstoneParam": [
                "protocol": "V2", "console": "ONE_CONSOLE", "productCode": "p_efm", "switchUserType": 3,
                "consoleSite": config.region == .china ? "BAILIAN_ALIYUN" : "MODELSTUDIO_ALBABACLOUD",
                "domain": config.dashboardURL.host!, "feURL": config.dashboardURL.absoluteString
            ]]]
        } else {
            params = ["ProductCode": config.region == .china ? "sfm_tokenplanteams_dp_cn" : "sfm_tokenplanteams_dp_intl"]
        }
        var fields = ["action": action, "product": product, "region": config.region.rawValue,
                      "params": String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)]
        if let secToken, !secToken.isEmpty { fields["sec_token"] = secToken }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        var request = baseRequest(url: url.url!, config: config)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(config.region.origin, forHTTPHeaderField: "Origin")
        request.setValue(config.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        let csrf = values["login_aliyunid_csrf"] ?? values["csrf"]
        request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
        request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        return request
    }

    /// Only known envelope keys are traversed. Never select an arbitrary seat,
    /// model, or first entry from a list and call it the account's total quota.
    static func payload(_ data: Data) throws -> [String: Any] {
        guard data.count <= 2 * 1024 * 1024 else { throw AlibabaTokenPlanError.invalidResponse }
        var value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw AlibabaTokenPlanError.invalidResponse }
        for _ in 0..<8 {
            if let text = value as? String, let raw = text.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: raw) {
                value = decoded
                continue
            }
            guard let object = value as? [String: Any] else { throw AlibabaTokenPlanError.invalidResponse }
            try checkError(object)
            let quotaKeys = ["TotalValue", "totalValue", "totalQuota", "totalCredits", "per5HourPercentage", "per1WeekPercentage"]
            if quotaKeys.contains(where: { object[$0] != nil }) { return object }
            let envelope = ["Data", "data", "DataV2", "successResponse", "body", "result"]
                .compactMap { object[$0] }.first { $0 is [String: Any] || $0 is String }
            guard let envelope else { throw AlibabaTokenPlanError.unavailable }
            value = envelope
        }
        throw AlibabaTokenPlanError.invalidResponse
    }

    private static func checkError(_ object: [String: Any]) throws {
        let code = (object["Code"] ?? object["code"] ?? object["errorCode"]).map { String(describing: $0).lowercased() } ?? ""
        if code.contains("notlogined") || code.contains("loginrequired") || code == "401" {
            throw AlibabaTokenPlanError.authentication
        }
        if object["Success"] as? Bool == false || object["success"] as? Bool == false
            || object["successResponse"] as? Bool == false
            || (!code.isEmpty && !["200", "success", "0"].contains(code)) {
            throw AlibabaTokenPlanError.requestFailed
        }
    }

    static func parse(_ data: Data, configuration config: AlibabaTokenPlanConfiguration, now: Date) throws -> ProviderQuota {
        let object = try payload(data)
        let primary: QuotaWindow
        var secondary: QuotaWindow?
        if config.edition == .team {
            guard let total = number(object["TotalValue"] ?? object["totalValue"] ?? object["totalQuota"] ?? object["totalCredits"]), total > 0,
                  let remaining = number(object["TotalSurplusValue"] ?? object["totalSurplusValue"] ?? object["remainingQuota"] ?? object["remainingCredits"]),
                  remaining >= 0, remaining <= total else { throw AlibabaTokenPlanError.unavailable }
            primary = QuotaWindow(
                usedPercent: (1 - remaining / total) * 100,
                windowMinutes: 30 * 24 * 60,
                // An expiry of one entitlement is not necessarily a pool reset.
                resetsAt: date(object["cycleEndTime"] ?? object["CycleEndTime"] ?? object["resetTime"]),
                remainingCredits: remaining
            )
        } else {
            var windows: [QuotaWindow] = []
            for (key, resetKey, minutes) in [("per5HourPercentage", "per5HourResetTime", 300),
                                            ("per1WeekPercentage", "per1WeekResetTime", 10080)] {
                guard let raw = object[key], !(raw is NSNull) else { continue }
                guard let ratio = number(raw), (0...1).contains(ratio) else { throw AlibabaTokenPlanError.invalidResponse }
                windows.append(QuotaWindow(usedPercent: ratio * 100, windowMinutes: minutes, resetsAt: date(object[resetKey])))
            }
            guard let first = windows.first else { throw AlibabaTokenPlanError.unavailable }
            primary = first
            secondary = windows.count > 1 ? windows[1] : nil
        }
        return ProviderQuota(provider: .alibabaTokenPlan, primary: primary, secondary: secondary,
                             planName: "\(config.edition.displayName) · \(config.region == .china ? "CN" : "INTL")", capturedAt: now)
    }

    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let raw = value as? NSNumber {
            guard CFGetTypeID(raw) != CFBooleanGetTypeID() else { return nil }
            number = raw.doubleValue
        } else if let raw = value as? String { number = Double(raw) }
        else { number = nil }
        return number?.isFinite == true ? number : nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = number(value), value > 0 {
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    static func secToken(in data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: #"(?:SEC_TOKEN|secToken|sec_token)[\"']?\s*[:=]\s*[\"']([^\"'\s<>]{1,4096})[\"']"#),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func network(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AlibabaTokenPlanError.invalidResponse }
        return (data, response)
    }
}
