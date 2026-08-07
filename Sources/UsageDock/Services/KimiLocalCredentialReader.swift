import Foundation

/// Kimi Code CLI 在 `~/.kimi-code/credentials/kimi-code.json` 落盘的
/// OAuth 凭证(对照 CodexBar `KimiSettingsReader` 的已验证口径)。
/// 凭证归 CLI 所有:只读 `access_token`,绝不代刷、绝不写回;
/// `expires_at` 距今不足 60 秒安全余量即视为不可用,换新完全交给 CLI。
struct KimiLocalCredential: Equatable, Sendable {
    let accessToken: String
    /// CLI 已生成的 `device_id`(若存在)。缺失时绝不补建文件。
    let deviceID: String?
}

struct KimiLocalCredentialReader {
    static let homeEnvironmentKey = "KIMI_CODE_HOME"
    /// 用户覆写了 Kimi Code 接口主机时放弃自动发现:CLI 凭证只应发往
    /// 官方 `api.kimi.com`,不能跟随自定义主机外流。
    static let endpointOverrideEnvironmentKeys = [
        "KIMI_CODE_BASE_URL", "KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"
    ]
    static let freshnessMargin: TimeInterval = 60
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var environment: [String: String] = ProcessInfo.processInfo.environment

    var kimiCodeHome: URL {
        if let override = environment[Self.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return homeDirectory.appending(path: ".kimi-code")
    }

    var credentialFileURL: URL {
        kimiCodeHome.appending(path: "credentials/kimi-code.json")
    }

    /// 仅当凭证文件存在、access_token 非空且距过期还有安全余量时返回;
    /// 其余情况(未安装、损坏、过期、主机被覆写)一律返回 nil,交由
    /// 手动凭证流程兜底。
    func load(now: Date = .now) -> KimiLocalCredential? {
        guard !hasEndpointOverride,
              let data = try? Data(contentsOf: credentialFileURL),
              let token = Self.freshAccessToken(fromCredentialsData: data, now: now) else {
            return nil
        }
        return KimiLocalCredential(accessToken: token, deviceID: deviceID)
    }

    var hasEndpointOverride: Bool {
        Self.endpointOverrideEnvironmentKeys.contains {
            environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// 只读取 CLI 已写好的 `device_id`;文件缺失时不生成、不落盘。
    private var deviceID: String? {
        let url = kimiCodeHome.appending(path: "device_id")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func freshAccessToken(fromCredentialsData data: Data, now: Date) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = (object["access_token"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let expiresAt = expiryDate(object["expires_at"]),
              expiresAt > now.addingTimeInterval(freshnessMargin) else {
            return nil
        }
        return token
    }

    /// `expires_at` 是 epoch 秒(CLI 口径),数字或数字字符串都接受;
    /// 异常大的值按毫秒归一。缺失/非法即视为不可用——绝不把过期状态
    /// 当作"永不过期"。
    static func expiryDate(_ value: Any?) -> Date? {
        let epoch: Double?
        if let number = value as? NSNumber {
            epoch = number.doubleValue
        } else if let text = value as? String {
            epoch = Double(text.trimmingCharacters(in: .whitespaces))
        } else {
            epoch = nil
        }
        guard let epoch, epoch.isFinite, epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch > 1e11 ? epoch / 1000 : epoch)
    }

    /// CLI access_token 的请求头:固定官方 Code API、Bearer 鉴权,附上
    /// CLI 平台标识与既有 device_id。即便 token 形如 JWT,也绝不能套用
    /// kimi-auth 网页端(www.kimi.com/apiv2)口径。
    static func requestHeaders(for credential: KimiLocalCredential) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(credential.accessToken)",
            "Accept": "application/json",
            "X-Msh-Platform": "kimi_code_cli"
        ]
        if let deviceID = credential.deviceID {
            headers["X-Msh-Device-Id"] = deviceID
        }
        return headers
    }
}
