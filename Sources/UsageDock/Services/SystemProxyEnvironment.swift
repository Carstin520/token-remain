import CFNetwork
import Foundation

/// GUI 进程没有 shell 代理变量，而 Claude CLI 的 Node 网络栈不会读取
/// macOS 系统代理。这里只把系统配置投影成子进程环境；调用方已有的显式
/// 代理配置优先，避免 UsageDock 改写用户选择的路由。
enum SystemProxyEnvironment {
    static func applyingSystemSettings(to environment: [String: String]) -> [String: String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
            as? [String: Any] else {
            return environment
        }
        return applying(settings, to: environment)
    }

    static func applying(
        _ settings: [String: Any],
        to environment: [String: String]
    ) -> [String: String] {
        var result = environment

        if let proxy = proxyURL(
            settings: settings,
            enabledKey: "HTTPEnable",
            hostKey: "HTTPProxy",
            portKey: "HTTPPort",
            scheme: "http"
        ) {
            set(proxy, for: ["HTTP_PROXY", "http_proxy"], in: &result)
        }
        if let proxy = proxyURL(
            settings: settings,
            enabledKey: "HTTPSEnable",
            hostKey: "HTTPSProxy",
            portKey: "HTTPSPort",
            scheme: "http"
        ) {
            set(proxy, for: ["HTTPS_PROXY", "https_proxy"], in: &result)
        }
        if let proxy = proxyURL(
            settings: settings,
            enabledKey: "SOCKSEnable",
            hostKey: "SOCKSProxy",
            portKey: "SOCKSPort",
            scheme: "socks5"
        ) {
            set(proxy, for: ["ALL_PROXY", "all_proxy"], in: &result)
        }

        let exclusions = (settings["ExceptionsList"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        if let exclusions, !exclusions.isEmpty {
            set(exclusions, for: ["NO_PROXY", "no_proxy"], in: &result)
        }

        return result
    }

    private static func proxyURL(
        settings: [String: Any],
        enabledKey: String,
        hostKey: String,
        portKey: String,
        scheme: String
    ) -> String? {
        guard (settings[enabledKey] as? NSNumber)?.boolValue == true,
              let host = (settings[hostKey] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = (settings[portKey] as? NSNumber)?.intValue,
           (1...65_535).contains(port) {
            components.port = port
        }
        return components.string
    }

    private static func set(
        _ value: String,
        for keys: [String],
        in environment: inout [String: String]
    ) {
        // 大小写变量是同一项配置；任一变体已经存在时整组保留，否则新加的
        // 另一变体可能在不同 Node 依赖里反而取得更高优先级。
        guard !keys.contains(where: { environment[$0] != nil }) else { return }
        keys.forEach { environment[$0] = value }
    }
}
