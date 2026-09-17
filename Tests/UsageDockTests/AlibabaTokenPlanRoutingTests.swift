import Foundation
import Testing
@testable import UsageDock

@Suite("Alibaba Token Plan routing")
struct AlibabaTokenPlanRoutingTests {
    @Test func recognizesTokenPlanInsteadOfGenericJSONAdapter() {
        for region in ["cn-beijing", "ap-southeast-1"] {
            let route = HostAppQuotaRouteDetector.classify(
                providerID: "anthropic",
                baseURL: URL(string: "https://token-plan.\(region).maas.aliyuncs.com/apps/anthropic")
            )
            #expect(route.displayName == "Alibaba Token Plan")
            #expect(route.provider != .thirdParty)
        }
    }
}

extension AlibabaTokenPlanRoutingTests {
    @Test func otherAliyunAPIsAndLookalikesStayGeneric() {
        for host in ["dashscope.aliyuncs.com", "token-plan.cn-beijing.maas.aliyuncs.com.evil.invalid", "api.minimax.io"] {
            let route = HostAppQuotaRouteDetector.classify(providerID: "alibaba-token-plan", baseURL: URL(string: "https://\(host)"))
            #expect(route.provider != .alibabaTokenPlan)
        }
    }

    @Test func routeAPIKeyNeverFallsBackToAnUnrelatedConsoleAccount() async {
        let detector = HostAppQuotaRouteDetector(
            homeDirectory: URL(fileURLWithPath: "/tmp/unused-alibaba-routing-fixture"),
            environment: ["ANTHROPIC_BASE_URL": "https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic",
                          "ANTHROPIC_AUTH_TOKEN": "fixture-api-key-never-send"]
        )
        let route = detector.route(for: .claude)
        do {
            _ = try await HostAppQuotaRoutingService(detector: detector).fetchExternal(route)
            Issue.record("A route key does not establish console account ownership")
        } catch {
            #expect(error.localizedDescription.contains(L10n.text("alibaba.route_setup")))
            #expect(!error.localizedDescription.contains("fixture-api-key-never-send"))
            #expect(!error.localizedDescription.contains("JSON"))
        }
    }
}
