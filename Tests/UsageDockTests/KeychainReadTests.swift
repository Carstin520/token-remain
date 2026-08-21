import Foundation
import Security
import Testing

@testable import UsageDock

/// `KeychainRead` 的行为契约。
///
/// 这些测试断言的是 set→read→restore 的**执行顺序**,而不是某个布尔值有没有被
/// 透传下去 —— 上一版的回归就发生在参数之外的那一层:参数一路传对了,但真正
/// 用来禁止交互的 API 选错了,未授权读取会阻塞到用户点击而不是返回错误。
@Suite("Keychain read interaction contract")
struct KeychainReadTests {
    /// 记录一次 read 里发生的动作序列。
    private final class Trace {
        var steps: [String] = []
    }

    private func probe(
        interaction: KeychainRead.Interaction,
        gate: NSLock = NSLock(),
        waitLimit: TimeInterval = 0.05,
        copyStatus: OSStatus = errSecSuccess,
        copyData: Data? = Data("payload".utf8)
    ) -> (outcome: KeychainRead.Outcome, steps: [String]) {
        let trace = Trace()
        let outcome = KeychainRead.read(
            query: [kSecAttrService as String: "test-service"],
            interaction: interaction,
            gate: gate,
            waitLimit: waitLimit,
            setLegacyInteractionAllowed: { allowed in
                trace.steps.append("set(\(allowed))")
                return errSecSuccess
            },
            copy: { query in
                let hasContext = query[kSecUseAuthenticationContext as String] != nil
                trace.steps.append("copy(context: \(hasContext))")
                return (copyStatus, copyData)
            }
        )
        return (outcome, trace.steps)
    }

    @Test("A silent read disables legacy Keychain UI around the read and restores it after")
    func silentReadBracketsTheRead() {
        let result = probe(interaction: .disallowed)
        // 顺序是全部:先关闸门,再读,读完必须还原,否则整个进程后续都不再弹窗。
        #expect(result.steps == ["set(false)", "copy(context: true)", "set(true)"])
        #expect(result.outcome.payload == "payload")
    }

    @Test("An interactive read never touches the process-wide switch")
    func interactiveReadLeavesTheSwitchAlone() {
        let result = probe(interaction: .allowed)
        #expect(result.steps == ["copy(context: false)"])
        #expect(result.outcome.payload == "payload")
    }

    @Test("The switch is restored even when the read fails")
    func switchIsRestoredOnFailure() {
        let result = probe(interaction: .disallowed, copyStatus: errSecAuthFailed, copyData: nil)
        #expect(result.steps == ["set(false)", "copy(context: true)", "set(true)"])
        #expect(result.outcome.payload == nil)
    }

    @Test("A refused item is reported as needing authorization, a missing item is not")
    func authorizationFailureIsDistinguishableFromAbsence() {
        // -25293 是实测中 legacy 条目在关掉交互后返回的状态码。
        let refused = probe(interaction: .disallowed, copyStatus: errSecAuthFailed, copyData: nil)
        #expect(refused.outcome.needsAuthorization)

        let absent = probe(interaction: .disallowed, copyStatus: errSecItemNotFound, copyData: nil)
        #expect(absent.outcome.needsAuthorization == false)
        #expect(absent.outcome.payload == nil)
    }

    @Test("A silent read gives up rather than queueing behind a live authorization dialog")
    func silentReadNeverBlocksOnALiveDialog() {
        let gate = NSLock()
        gate.lock()
        defer { gate.unlock() }

        // 交互式读取正等着用户点击时,后台刷新等到超时就放弃并降级,
        // 而不是把刷新任务排在系统弹窗后面无限期等下去。
        let started = Date()
        let result = probe(interaction: .disallowed, gate: gate, waitLimit: 0.05)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(result.steps.isEmpty)
        #expect(result.outcome.payload == nil)
        #expect(result.outcome.needsAuthorization)
    }

    /// 刷新是并发的:Claude / Cursor / Copilot / Antigravity 会同时读钥匙串。
    /// 它们之间的锁竞争是良性的(一次读取毫秒级),**必须**互相等一下;早期实现
    /// 用 `NSLock.try()` 直接失败,会让其中一个白白降级到 30 秒的 PTY 探针。
    @Test("Concurrent silent reads all succeed instead of losing a race for the switch")
    func concurrentSilentReadsAllSucceed() async {
        let gate = NSLock()
        let results = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    KeychainRead.read(
                        query: [kSecAttrService as String: "test-service"],
                        interaction: .disallowed,
                        gate: gate,
                        setLegacyInteractionAllowed: { _ in errSecSuccess },
                        copy: { _ in (errSecSuccess, Data("payload".utf8)) }
                    ).payload
                }
            }
            var collected: [String?] = []
            for await value in group { collected.append(value) }
            return collected
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == "payload" })
    }

    @Test("A refused switch aborts before reading instead of reading with UI enabled")
    func abortsWhenTheSwitchCannotBeSet() {
        let trace = Trace()
        let outcome = KeychainRead.read(
            query: [kSecAttrService as String: "test-service"],
            interaction: .disallowed,
            gate: NSLock(),
            setLegacyInteractionAllowed: { _ in errSecNotAvailable },
            copy: { _ in
                trace.steps.append("copy")
                return (errSecSuccess, Data("payload".utf8))
            }
        )
        #expect(trace.steps.isEmpty)
        #expect(outcome.payload == nil)
    }

    /// 还原失败不能吞掉读取结果,也不能让调用方以为读取本身失败了。
    /// (还原失败会被记进 com.jamesli.usagedock 的 Keychain 日志,不在这里断言。)
    @Test("A failed restore still yields the value that was read")
    func failedRestoreDoesNotLoseTheRead() {
        var calls: [Bool] = []
        let outcome = KeychainRead.read(
            query: [kSecAttrService as String: "test-service"],
            interaction: .disallowed,
            gate: NSLock(),
            setLegacyInteractionAllowed: { allowed in
                calls.append(allowed)
                return allowed ? errSecNotAvailable : errSecSuccess
            },
            copy: { _ in (errSecSuccess, Data("payload".utf8)) }
        )
        #expect(calls == [false, true])
        #expect(outcome.payload == "payload")
    }

    @Test("Non-UTF8 data is rejected rather than surfaced as a garbled secret")
    func rejectsNonUTF8Payload() {
        let invalid = Data([0xFF, 0xFE, 0xFD])
        let result = probe(interaction: .disallowed, copyData: invalid)
        #expect(result.outcome.payload == nil)
    }
}

/// 真机 ACL 回归探针。测试二进制不在 `Claude Code-credentials` 的 ACL 信任
/// 列表里,所以**正确行为是立刻读不到**;一旦禁止交互失效,这次读取会阻塞到
/// 用户点击授权框,断言就会因为超时而失败。
///
/// `/usr/bin/security` 委托读取的**判据解析**。判据本身(条目 ACL 允许该工具
/// 解密、partition list 收录 `apple-tool:`、钥匙串未锁)决定了委托路径永远不会
/// 弹框;真机那一半由下面的 opt-in 探针覆盖,这里锁住的是解析。
@Suite("Keychain Apple tool gate parsing")
struct KeychainAppleToolGateTests {
    private func partitionDescription(
        _ partitions: [String],
        hexEncoded: Bool
    ) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Partitions": partitions],
            format: .xml,
            options: 0
        )
        guard hexEncoded else {
            return try #require(String(data: data, encoding: .utf8))
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("Reads the partition list macOS keeps hex-encoded in the ACL description")
    func readsHexEncodedPartitions() throws {
        let description = try partitionDescription(["apple-tool:"], hexEncoded: true)
        #expect(KeychainRead.partitions(inACLDescription: description) == ["apple-tool:"])
    }

    /// 只认十六进制形态就把判据绑在一个未公开的编码细节上;两种都接受,哪天
    /// macOS 换回明文也不会让委托路径整体失效、静默退回抓屏。
    @Test("Accepts a plain plist description as well")
    func readsPlainPartitions() throws {
        let description = try partitionDescription(
            ["apple-tool:", "teamid:ABCDE12345"],
            hexEncoded: false
        )
        #expect(
            KeychainRead.partitions(inACLDescription: description)
                == ["apple-tool:", "teamid:ABCDE12345"]
        )
    }

    @Test("A description that is not a partition plist yields nil")
    func rejectsUnrelatedDescription() {
        #expect(KeychainRead.partitions(inACLDescription: "Claude Code-credentials") == nil)
        #expect(KeychainRead.partitions(inACLDescription: "") == nil)
        #expect(KeychainRead.partitions(inACLDescription: nil) == nil)
    }

    /// 信任列表里的条目是路径 blob。把这里放宽会让"某个别的应用被信任"误判成
    /// "Apple 工具被信任",而后者才是不弹框的前提。
    @Test("Only the Apple tool's own path counts as the delegate")
    func matchesAppleToolPath() {
        #expect(KeychainRead.isAppleTool(trustedApplicationData: Data("/usr/bin/security\0".utf8)))
        #expect(
            !KeychainRead.isAppleTool(
                trustedApplicationData: Data("/Users/me/Applications/TokenRemain.app\0".utf8)
            )
        )
        #expect(!KeychainRead.isAppleTool(trustedApplicationData: Data()))
    }
}

/// 真机探针:证明委托路径确实能静默读到这台机器上 GUI 应用读不到的条目。
/// 默认跳过(依赖本机存在 Claude Code 的钥匙串条目)。本机执行:
///
///     USAGEDOCK_KEYCHAIN_ACL_PROBE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///         swift test --filter KeychainAppleToolProbeTests
@Suite("Keychain Apple tool delegate probe (opt-in)")
struct KeychainAppleToolProbeTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["USAGEDOCK_KEYCHAIN_ACL_PROBE"] == "1"
    }

    @Test("The Apple tool reaches the item this process is locked out of",
          .enabled(if: KeychainAppleToolProbeTests.enabled))
    func delegateReadsWhatTheProcessCannot() async {
        let service = ClaudeCredentialsReader.keychainService
        let direct = KeychainRead.genericPassword(service: service, interaction: .disallowed)
        #expect(
            direct.needsAuthorization,
            """
            expected the direct read to be refused, got OSStatus \(direct.status). \
            If this is errSecItemNotFound (-25300) the probe proved nothing; if the \
            read succeeded, this machine is already inside the item's partition.
            """
        )
        #expect(KeychainRead.appleToolMayDecrypt(service: service))

        let started = Date()
        let delegated = await KeychainRead.genericPasswordViaAppleTool(service: service)
        let elapsed = Date().timeIntervalSince(started)

        // 延迟断言是这条探针的重点:委托读取只该花毫秒级,秒级说明有人在等一次
        // 点击 —— 那正是自动刷新绝不允许出现的东西。
        #expect(elapsed < 5, "delegated read took \(elapsed)s — a dialog may have appeared")
        #expect(delegated.status == errSecSuccess)
        // 只断言形状,绝不记录内容。
        #expect(delegated.payload?.hasPrefix("{") == true)
    }
}

/// 默认跳过:它依赖本机真实存在该钥匙串条目,而且回归时会弹出系统授权框
/// (那正是它在报警)。本机执行:
///
///     USAGEDOCK_KEYCHAIN_ACL_PROBE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///         swift test --filter KeychainACLProbeTests
@Suite("Keychain ACL probe (opt-in)")
struct KeychainACLProbeTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["USAGEDOCK_KEYCHAIN_ACL_PROBE"] == "1"
    }

    @Test("An unauthorized silent read returns promptly instead of waiting on a dialog",
          .enabled(if: KeychainACLProbeTests.enabled))
    func unauthorizedReadFailsFast() {
        let started = Date()
        let outcome = KeychainRead.genericPassword(
            service: ClaudeCredentialsReader.keychainService,
            interaction: .disallowed
        )
        let elapsed = Date().timeIntervalSince(started)

        // 延迟断言区分"静默失败"和"弹框等人点"。
        #expect(elapsed < 2, "silent keychain read took \(elapsed)s — interaction suppression regressed")
        #expect(outcome.payload == nil)
        // 状态码断言堵掉假通过:只断言 payload 为 nil 的话,在一台根本没有这条
        // 钥匙串条目的机器上,errSecItemNotFound 会又快又空地"通过",而抑制机制
        // 一次都没被执行到。needsAuthorization 明确排除了 errSecItemNotFound,
        // 于是"条目必须存在"这个前提变成了断言本身。
        #expect(
            outcome.needsAuthorization,
            """
            expected an authorization refusal, got OSStatus \(outcome.status). \
            If this is errSecItemNotFound (-25300), this machine has no \
            "\(ClaudeCredentialsReader.keychainService)" item and the probe proved nothing.
            """
        )
    }
}

/// 已授权读取的回归探针 —— 上面那条的镜像。
///
/// `SecKeychainSetUserInteractionAllowed(false)` 只应该掐掉"需要弹框"的读取。
/// 如果它连已授权的读取一起掐掉,后果不是"不再弹窗"而是"用量彻底读不到",
/// 所以这一侧必须单独证明。做法:测试进程**自己创建**一条条目 —— 它对自己
/// 创建的条目天然在 ACL 信任列表内 —— 再用 `.disallowed` 读回来。
///
/// 默认跳过:它会往 login keychain 写一条一次性条目(值是随机 UUID,不是任何
/// 真实凭据),读完立即删除,不触碰任何现有条目的 ACL。本机执行:
///
///     USAGEDOCK_KEYCHAIN_SELFTEST=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///         swift test --filter KeychainAuthorizedReadTests
@Suite("Keychain authorized read (opt-in, writes a throwaway item)")
struct KeychainAuthorizedReadTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["USAGEDOCK_KEYCHAIN_SELFTEST"] == "1"
    }

    @Test("Suppressing interaction does not break a read the process is authorized for",
          .enabled(if: KeychainAuthorizedReadTests.enabled))
    func authorizedReadStillSucceeds() throws {
        let service = "com.jamesli.usagedock.acl-selftest"
        let account = "selftest-\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service, account: account)
        let value = "selftest-\(UUID().uuidString)"

        try store.save(value)
        defer { try? store.delete() }
        #expect(try store.read() == value, "KeychainSecretStore.read must preserve an authorized value")

        let started = Date()
        let outcome = KeychainRead.genericPassword(
            service: service,
            account: account,
            interaction: .disallowed
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcome.payload == value, "the process-wide switch broke an authorized read")
        #expect(outcome.status == errSecSuccess)
        #expect(outcome.needsAuthorization == false)
        #expect(elapsed < 2)
    }
}
