import CryptoKit
import Foundation

/// ZCode 桌面端/CLI 在 `~/.zcode/v2` 落盘的凭证与计划配置只读发现,
/// 对照 TokenTracker `src/lib/zcode-limits.js` 的已验证口径。所有读取
/// 均为只读:绝不写回配置、绝不代刷 token、解密失败即放弃该值。
///
/// 辖区边界:每个候选凭证自带归属(builtin:zai-* → Z.ai 国际,
/// builtin:bigmodel-* → 智谱国内),端点由归属唯一决定,绝不把一个
/// 辖区的凭证发往另一辖区,也不参与用户手动 Key 的显式区域选择。

/// 计划形态:coding-plan 走 monitor 限额接口(裸 token),
/// start-plan 走 zcode.z.ai 计费余额接口(Bearer + ZCode 头)。
enum ZCodePlanKind: String, Sendable {
    case coding
    case start
}

/// 凭证归属辖区(仅对 coding-plan 决定 monitor 主机)。
enum ZCodePlanRegion: String, Sendable {
    case zai
    case bigmodel
}

struct ZCodeAuthCandidate: Equatable, Sendable {
    let providerKey: String
    let planKind: ZCodePlanKind
    let region: ZCodePlanRegion
    let token: String
    /// "credential:zcodejwttoken"(登录态)或 "provider:config"(配置内 Key)。
    let authSource: String
    /// coding-plan 的 `options.baseURL`;仅 api.z.ai 域名会用于覆写 monitor 主机。
    let baseURL: String?
}

struct ZCodeCredentialReader {
    static let homeEnvironmentKey = "ZCODE_HOME"
    static let secretEnvironmentKey = "ZCODE_CREDENTIAL_SECRET"
    /// 默认候选顺序与 TokenTracker 一致:start-plan 在前(登录态覆盖面
    /// 最广),同形态先国内后国际。
    static let defaultCandidateKeys = [
        "builtin:bigmodel-start-plan",
        "builtin:zai-start-plan",
        "builtin:bigmodel-coding-plan",
        "builtin:zai-coding-plan"
    ]

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var username: String = NSUserName()
    /// Node `process.platform` 口径;密钥派生串的一部分。
    var platform: String = "darwin"

    var zcodeHome: URL {
        if let override = environment[Self.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return homeDirectory.appending(path: ".zcode")
    }

    // MARK: 候选构建

    /// `config.json` 内置计划 provider → 有序去重的可用凭证候选。
    /// 排序:setting.json 显式选择 → 缓存标记 available → 默认顺序;
    /// enabled == false 或缓存标记不可用的条目剔除。
    func authCandidates() -> [ZCodeAuthCandidate] {
        guard let config = json(at: "v2/config.json"),
              let providers = config["provider"] as? [String: Any] else {
            return []
        }
        let availability = providerAvailability()
        let ordered = (
            selectedPlanProviderKeys().filter { Self.defaultCandidateKeys.contains($0) }
                + Self.defaultCandidateKeys.filter { availability[$0] == "available" }
                + Self.defaultCandidateKeys
        )
        var seenKeys = Set<String>()
        var candidates: [ZCodeAuthCandidate] = []
        for key in ordered where seenKeys.insert(key).inserted {
            guard let provider = providers[key] as? [String: Any],
                  provider["enabled"] as? Bool != false,
                  let (kind, region) = Self.plan(forProviderKey: key) else {
                continue
            }
            if !availability.isEmpty, let status = availability[key], status != "available" {
                continue
            }
            let options = provider["options"] as? [String: Any]
            let baseURL = (options?["baseURL"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let configKey = (options?["apiKey"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var tokens: [(String, String)] = []
            if kind == .start, activeProvider == region.rawValue,
               let jwt = credentialValue("zcodejwttoken") {
                tokens.append((jwt, "credential:zcodejwttoken"))
            }
            if !configKey.isEmpty {
                tokens.append((configKey, "provider:config"))
            }
            var seenTokens = Set<String>()
            for (token, source) in tokens where seenTokens.insert(token).inserted {
                candidates.append(ZCodeAuthCandidate(
                    providerKey: key,
                    planKind: kind,
                    region: region,
                    token: token,
                    authSource: source,
                    baseURL: baseURL?.isEmpty == false ? baseURL : nil
                ))
            }
        }
        return candidates
    }

    static func plan(forProviderKey key: String) -> (ZCodePlanKind, ZCodePlanRegion)? {
        let pattern = #"^builtin:(bigmodel|zai)-(start|coding)-plan$"#
        guard key.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let region: ZCodePlanRegion = key.contains(":zai-") ? .zai : .bigmodel
        let kind: ZCodePlanKind = key.contains("-coding-plan") ? .coding : .start
        return (kind, region)
    }

    /// `setting.json` 的 `providerFamilyDomain` + `modelProviderFamilySelectedKeys`
    /// 中形如 `builtin:{zai,bigmodel}-{start,coding}-plan` 的选中项。
    func selectedPlanProviderKeys() -> [String] {
        guard let setting = json(at: "v2/setting.json"),
              let selected = setting["modelProviderFamilySelectedKeys"] as? [String: Any] else {
            return []
        }
        let domain = setting["providerFamilyDomain"] as? String ?? ""
        var keys: [String] = []
        for domainKey in ([domain] + selected.keys.sorted()) where !domainKey.isEmpty {
            guard let raw = (selected[domainKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let range = raw.range(
                    of: #"builtin:(bigmodel|zai)-(start|coding)-plan"#,
                    options: .regularExpression
                ) else {
                continue
            }
            let key = String(raw[range])
            if !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// `coding-plan-cache.json` 的 `entryStatus.items` → providerKey: status。
    func providerAvailability() -> [String: String] {
        guard let cache = json(at: "v2/coding-plan-cache.json"),
              let entryStatus = cache["entryStatus"] as? [String: Any],
              let items = entryStatus["items"] as? [String: Any] else {
            return [:]
        }
        var statuses: [String: String] = [:]
        for (key, value) in items {
            if let entry = value as? [String: Any], let status = entry["status"] as? String {
                statuses[key] = status
            }
        }
        return statuses
    }

    var activeProvider: String? {
        credentialValue("oauth:active_provider")
    }

    // MARK: credentials.json 解密

    /// `credentials.json` 单个条目:明文直接返回,`enc:v1:` 前缀走
    /// AES-256-GCM 解密;解密失败或为空一律返回 nil。
    func credentialValue(_ name: String) -> String? {
        guard let credentials = json(at: "v2/credentials.json"),
              let raw = credentials[name] as? String else {
            return nil
        }
        let value = Self.decrypt(raw, secret: credentialSecret)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// ZCode 的兜底密钥派生串(与 TokenTracker/ZCode 同源):
    /// `zcode-credential-fallback:<platform>:<home>:<username>`,
    /// 环境变量 `ZCODE_CREDENTIAL_SECRET` 可覆写。
    var credentialSecret: String {
        if let secret = environment[Self.secretEnvironmentKey], !secret.isEmpty {
            return secret
        }
        let home = homeDirectory.path
        return "zcode-credential-fallback:\(platform):\(home):\(username)"
    }

    /// `enc:v1:<iv>.<tag>.<ciphertext>`(base64url)→ 明文;
    /// key = SHA-256(secret)。非该格式的值原样返回,坏帧返回 nil。
    static func decrypt(_ value: String, secret: String) -> String? {
        guard value.hasPrefix("enc:v1:") else { return value }
        let parts = value.dropFirst("enc:v1:".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let iv = base64URLDecoded(String(parts[0])),
              let tag = base64URLDecoded(String(parts[1])),
              let ciphertext = base64URLDecoded(String(parts[2])),
              let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) else {
            return nil
        }
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
        guard let plaintext = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plaintext, encoding: .utf8)
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        var encoded = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        return Data(base64Encoded: encoded)
    }

    private func json(at relativePath: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: zcodeHome.appending(path: relativePath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - 请求契约与响应解析

/// ZCode 凭证的两套请求契约(与 TokenTracker 实测一致,注意两者鉴权
/// 形态不同):
/// - coding-plan:`GET {monitor 主机}/api/monitor/usage/quota/limit`,
///   `Authorization` 直接放裸 token(不是 Bearer)。主机按辖区固定:
///   zai → api.z.ai,bigmodel → bigmodel.cn;仅当 config 里 baseURL
///   本就是 api.z.ai 域名时沿用其 origin。
/// - start-plan:`GET zcode.z.ai/api/v1/zcode-plan/billing/balance`,
///   `Bearer` + ZCode 客户端标头 + `app_version` 查询参数。
enum ZCodeQuotaContract {
    static let quotaPath = "/api/monitor/usage/quota/limit"
    static let billingBalanceURL = URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance")!
    /// 无法从已安装的 ZCode.app 读到版本时的保守兜底(CLI-only 安装)。
    static let fallbackAppVersion = "3.2.5"

    struct Request: Equatable {
        let url: URL
        let headers: [String: String]
    }

    static func request(
        for candidate: ZCodeAuthCandidate,
        appVersion: String,
        deviceMid: String? = nil
    ) -> Request {
        switch candidate.planKind {
        case .coding:
            return Request(
                url: monitorOrigin(for: candidate).appending(path: quotaPath),
                headers: [
                    "Authorization": candidate.token,
                    "Accept": "application/json"
                ]
            )
        case .start:
            var components = URLComponents(url: billingBalanceURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "app_version", value: appVersion)]
            var headers = sourceHeaders(appVersion: appVersion)
            headers["Authorization"] = "Bearer \(candidate.token)"
            headers["Accept"] = "application/json"
            if let deviceMid {
                headers["X-Device-Mid"] = deviceMid
            }
            return Request(url: components.url!, headers: headers)
        }
    }

    /// coding-plan monitor 主机:辖区唯一决定默认值;config 的 baseURL
    /// 只有归属 api.z.ai 域名时才沿用,其它主机一律忽略,防止把凭证
    /// 发往配置里被改过的第三方地址。
    static func monitorOrigin(for candidate: ZCodeAuthCandidate) -> URL {
        switch candidate.region {
        case .zai:
            if let base = candidate.baseURL,
               let url = URL(string: base),
               url.scheme == "https",
               let host = url.host()?.lowercased(),
               host == "api.z.ai" || host.hasSuffix(".api.z.ai"),
               let origin = URL(string: "https://\(host)") {
                return origin
            }
            return URL(string: "https://api.z.ai")!
        case .bigmodel:
            return URL(string: "https://bigmodel.cn")!
        }
    }

    /// start-plan 必带的 ZCode 客户端标头(缺 app_version 会被计费接口拒绝)。
    static func sourceHeaders(appVersion: String) -> [String: String] {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "User-Agent": "ZCode/\(appVersion)",
            "HTTP-Referer": "https://zcode.z.ai/",
            "X-ZCode-App-Version": appVersion,
            "X-Platform": "darwin",
            "X-Release-Channel": "stable",
            "X-Client-Language": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            "X-Client-Timezone": TimeZone.current.identifier,
            "X-Os-Category": "darwin",
            "X-Os-Version": "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        ]
    }

    /// 已安装 ZCode.app 的 `CFBundleShortVersionString`(只读),读不到
    /// 用保守兜底版本。
    static func appVersion(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let candidates = [
            URL(fileURLWithPath: "/Applications/ZCode.app/Contents/Info.plist"),
            home.appending(path: "Applications/ZCode.app/Contents/Info.plist")
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let info = plist as? [String: Any],
                  let version = (info["CFBundleShortVersionString"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !version.isEmpty else {
                continue
            }
            return version
        }
        return fallbackAppVersion
    }

    // MARK: start-plan 余额响应

    /// `data.balances[]`(show_name/total_units/used_units/period_end…)→
    /// ProviderQuota。balances 是模型级命名池(show_name 如 "GLM-5.2"):
    /// 最忙(已用百分比最高)的池做主窗口并带 poolName,其余池全部以命名
    /// scoped 窗口保留——绝不走 secondary,手机同步拒绝同 provider 两个
    /// 同时长的账户级窗口,scoped 则允许同时长,第 3+ 池也不再丢弃。
    /// 上游只给周期终点(period_end)没有起点,`period_end - server_time`
    /// 是"剩余时间"而非窗口时长,拿它当时长会逐次刷新缩水,污染时长标签
    /// 与配速计算——窗口时长固定按月度套餐节奏取 43_200 分钟,resetsAt
    /// 仍用真实 period_end;计划名取主窗口所属池的 plan_id;时间戳
    /// 为 epoch 秒。balances 为空或业务码非 0 视为该候选不可用。
    static func parseBilling(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data) else {
            throw ZAIUsageService.ServiceError.invalidResponse
        }
        if let code = ExtendedHTTP.number(body["code"]), code != 0, code != 200 {
            throw ZAIUsageService.ServiceError.invalidResponse
        }
        guard let payload = body["data"] as? [String: Any],
              let balances = payload["balances"] as? [[String: Any]],
              !balances.isEmpty else {
            throw ZAIUsageService.ServiceError.invalidResponse
        }

        struct Bucket {
            let showName: String?
            let planID: String?
            let usedPercent: Double
            let windowMinutes: Int
            let resetsAt: Date?
        }
        var buckets: [Bucket] = []
        for balance in balances {
            guard let total = ExtendedHTTP.number(balance["total_units"]), total > 0,
                  let used = ExtendedHTTP.number(balance["used_units"]), used >= 0 else {
                continue
            }
            let periodEnd = ExtendedHTTP.number(balance["period_end"])
                ?? ExtendedHTTP.number(balance["expires_at"])
            let resetsAt = periodEnd.flatMap { epoch -> Date? in
                guard epoch > 0 else { return nil }
                return Date(timeIntervalSince1970: epoch > 1e11 ? epoch / 1000 : epoch)
            }
            // 上游只给周期终点,无起点,固定月度时长避免逐刷缩水。
            let windowMinutes = 43_200
            let showName = (balance["show_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buckets.append(Bucket(
                showName: showName?.isEmpty == false ? showName : nil,
                planID: balance["plan_id"] as? String,
                usedPercent: ExtendedHTTP.clamp(used / total * 100),
                windowMinutes: windowMinutes,
                resetsAt: resetsAt
            ))
        }
        // 最忙的池才是真正的瓶颈;同用量按响应顺序稳定排序。
        let ordered = buckets.enumerated().sorted { lhs, rhs in
            lhs.element.usedPercent == rhs.element.usedPercent
                ? lhs.offset < rhs.offset
                : lhs.element.usedPercent > rhs.element.usedPercent
        }.map(\.element)
        guard let busiest = ordered.first else {
            throw ZAIUsageService.ServiceError.invalidResponse
        }
        var seenScopeIDs = Set<String>()
        var scopedWindows: [ScopedQuotaWindow] = []
        for (index, bucket) in ordered.dropFirst().enumerated() {
            scopedWindows.append(ScopedQuotaWindow(
                scopeID: ZAIUsageParser.scopeID(
                    prefix: "zcode_",
                    name: bucket.showName,
                    fallback: "pool_\(index + 2)",
                    seen: &seenScopeIDs
                ),
                displayName: bucket.showName ?? "Pool \(index + 2)",
                window: QuotaWindow(
                    usedPercent: bucket.usedPercent,
                    windowMinutes: bucket.windowMinutes,
                    resetsAt: bucket.resetsAt
                ),
                observedAt: now
            ))
        }
        return ProviderQuota(
            provider: .zai,
            primary: QuotaWindow(
                usedPercent: busiest.usedPercent,
                windowMinutes: busiest.windowMinutes,
                resetsAt: busiest.resetsAt,
                poolName: busiest.showName
            ),
            secondary: nil,
            planName: planLabel(fromPlanID: busiest.planID).map { "ZCode \($0)" } ?? "ZCode",
            capturedAt: now,
            scopedWindows: scopedWindows.isEmpty ? nil : scopedWindows
        )
    }

    /// coding-plan monitor 响应里的 `data.level`(如 "pro")→ 计划名。
    static func codingPlanName(_ data: Data) -> String? {
        guard let body = ExtendedHTTP.json(data) else { return nil }
        let payload = (body["data"] as? [String: Any]) ?? body
        guard let level = (payload["level"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !level.isEmpty else {
            return nil
        }
        return "ZCode \(planLabel(fromPlanID: level) ?? level)"
    }

    /// "zcode-v3-start-plan-0615" 这类原始 id 只提取人话档位词。
    static func planLabel(fromPlanID planID: String?) -> String? {
        guard let planID, !planID.isEmpty,
              let range = planID.lowercased().range(
                  of: #"\b(lite|start|pro|max|team|enterprise)\b"#,
                  options: .regularExpression
              ) else {
            return nil
        }
        let tier = String(planID.lowercased()[range])
        return tier.prefix(1).uppercased() + tier.dropFirst()
    }
}
