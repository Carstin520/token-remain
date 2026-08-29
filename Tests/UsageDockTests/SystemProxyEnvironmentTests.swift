import Foundation
import Testing
@testable import UsageDock

@Suite("System proxy process environment")
struct SystemProxyEnvironmentTests {
    @Test("Maps enabled macOS proxies and exclusions to both environment spellings")
    func mapsSystemProxySettings() {
        let settings: [String: Any] = [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 1082,
            "HTTPSEnable": 1,
            "HTTPSProxy": "secure-proxy.local",
            "HTTPSPort": 8443,
            "SOCKSEnable": 1,
            "SOCKSProxy": "socks-proxy.local",
            "SOCKSPort": 1080,
            "ExceptionsList": ["localhost", "*.internal"]
        ]

        let environment = SystemProxyEnvironment.applying(settings, to: ["TERM": "xterm"])

        #expect(environment["HTTP_PROXY"] == "http://127.0.0.1:1082")
        #expect(environment["http_proxy"] == "http://127.0.0.1:1082")
        #expect(environment["HTTPS_PROXY"] == "http://secure-proxy.local:8443")
        #expect(environment["https_proxy"] == "http://secure-proxy.local:8443")
        #expect(environment["ALL_PROXY"] == "socks5://socks-proxy.local:1080")
        #expect(environment["all_proxy"] == "socks5://socks-proxy.local:1080")
        #expect(environment["NO_PROXY"] == "localhost,*.internal")
        #expect(environment["no_proxy"] == "localhost,*.internal")
        #expect(environment["TERM"] == "xterm")
    }

    @Test("An existing variable in either spelling preserves the whole proxy group")
    func preservesExistingProxyVariables() {
        let settings: [String: Any] = [
            "HTTPEnable": 1,
            "HTTPProxy": "system-http.local",
            "HTTPPort": 8080,
            "HTTPSEnable": 1,
            "HTTPSProxy": "system-https.local",
            "HTTPSPort": 8443,
            "SOCKSEnable": 1,
            "SOCKSProxy": "system-socks.local",
            "SOCKSPort": 1080,
            "ExceptionsList": ["system.internal"]
        ]
        let existing = [
            "http_proxy": "http://custom-http.local:9000",
            "HTTPS_PROXY": "http://custom-https.local:9443",
            "all_proxy": "socks5://custom-socks.local:9001",
            "NO_PROXY": "custom.internal"
        ]

        let environment = SystemProxyEnvironment.applying(settings, to: existing)

        #expect(environment["http_proxy"] == existing["http_proxy"])
        #expect(environment["HTTP_PROXY"] == nil)
        #expect(environment["HTTPS_PROXY"] == existing["HTTPS_PROXY"])
        #expect(environment["https_proxy"] == nil)
        #expect(environment["all_proxy"] == existing["all_proxy"])
        #expect(environment["ALL_PROXY"] == nil)
        #expect(environment["NO_PROXY"] == existing["NO_PROXY"])
        #expect(environment["no_proxy"] == nil)
    }
}
