import Foundation
import LocalAuthentication
import OSLog
import Security

/// 只读钥匙串工具:按 service(可选 account)取第一条 generic password。
/// 供各 provider 的凭证发现使用;绝不写入。
enum KeychainRead {
    /// 本次读取是否允许召唤系统授权框。**故意不给默认值**:后台刷新链路上
    /// 任何一处漏写都应该是编译错误,而不是静默弹窗。
    enum Interaction {
        /// 自动刷新用。未授权时立即失败,由调用方降级到无提示的兜底路径。
        case disallowed
        /// 只能由明确的用户主动操作使用(例如设置页的「授权读取」按钮)。
        case allowed
    }

    struct Outcome: Sendable {
        let payload: String?
        let status: OSStatus

        /// 条目存在但本进程无权读取 —— 需要用户显式授权,和"根本没有这条凭证"
        /// (`errSecItemNotFound`)是两回事,调用方要能分开处理。
        var needsAuthorization: Bool {
            status == errSecAuthFailed
                || status == errSecInteractionNotAllowed
                || status == errSecUserCanceled
        }
    }

    /// `SecKeychainSetUserInteractionAllowed` 是**进程级**开关:并发刷新里一个
    /// 线程的还原会给另一个线程开弹窗闸门,所以整段 set→read→restore 必须串行。
    static let interactionGate = NSLock()

    /// 静默读取等锁的上限。刷新是并发的(Claude / Cursor / Copilot / Antigravity
    /// 同时读钥匙串),彼此之间**必须**互相等一下 —— 一次读取只要毫秒级,直接
    /// try-and-fail 会让其中一个白白降级到 30 秒的 PTY 探针。反过来,如果锁被
    /// 一个正在等用户点击的交互式读取占着,等待就会超时并降级,绝不排在弹窗后面。
    static let silentWaitLimit: TimeInterval = 0.5

    static func genericPassword(
        service: String,
        account: String? = nil,
        interaction: Interaction
    ) -> Outcome {
        read(query: query(service: service, account: account), interaction: interaction)
    }

    /// 可注入的核心。测试用它断言 set→read→restore 的**顺序**,而不是断言某个
    /// 布尔值有没有被透传下去 —— 上一版的回归恰恰发生在参数之外的这一层。
    static func read(
        query: [String: Any],
        interaction: Interaction,
        gate: NSLock = interactionGate,
        waitLimit: TimeInterval = silentWaitLimit,
        // 这里会报一条 `SecKeychain is deprecated` 警告,是**故意保留**的:
        // SecKeychain 系列虽已废弃,但它是唯一能关掉 legacy 钥匙串 ACL 授权框的
        // 开关,现代 API 没有等价物。警告本身就是"哪天 macOS 真的移除它,这里
        // 需要重新找方案"的提醒,不要用技巧把它藏掉。
        setLegacyInteractionAllowed: (Bool) -> OSStatus = { SecKeychainSetUserInteractionAllowed($0) },
        copy: ([String: Any]) -> (OSStatus, Data?) = systemCopy
    ) -> Outcome {
        switch interaction {
        case .allowed:
            // 交互式读取同样占锁,否则并发的静默读取会把这次弹窗一起压掉。
            gate.lock()
            defer { gate.unlock() }
            return outcome(copy(query))

        case .disallowed:
            // 短暂等待:并发的静默读取之间互相让路;超时说明锁被一个正在等用户
            // 点击的交互式读取占着,那就当作读不到,让调用方走兜底,绝不排队。
            guard gate.lock(before: Date().addingTimeInterval(waitLimit)) else {
                return Outcome(payload: nil, status: errSecInteractionNotAllowed)
            }
            defer { gate.unlock() }

            var query = query
            // 带 SecAccessControl 的 data-protection 条目认这个。Claude Code 等
            // CLI 写在 login.keychain 的 legacy 条目不认,靠下面的进程级开关。
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context

            // legacy(file-based)钥匙串的 ACL 授权框只认这个开关:
            // `kSecUseAuthenticationContext` 和 `kSecUseAuthenticationUIFail`
            // 都拦不住它,未授权的读取会一直**阻塞到用户点击**而不是返回错误,
            // 于是调用方的降级分支永远不会被执行。实测见 KeychainReadTests。
            guard setLegacyInteractionAllowed(false) == errSecSuccess else {
                return Outcome(payload: nil, status: errSecInteractionNotAllowed)
            }
            // 硬还原成 true 是安全的:GUI 进程默认允许交互,而 gate 保证这段
            // 不会嵌套 —— 全仓没有别的地方动过这个开关。
            defer {
                let restoreStatus = setLegacyInteractionAllowed(true)
                if restoreStatus != errSecSuccess {
                    // 还原失败的后果比看上去严重:此后本进程**所有**需要交互的
                    // 钥匙串读取都会静默失败,且不留痕迹。只记状态码,绝不记条目内容。
                    Logger(subsystem: "com.jamesli.usagedock", category: "Keychain")
                        .error("failed to restore keychain user interaction: OSStatus \(restoreStatus, privacy: .public)")
                }
            }
            return outcome(copy(query))
        }
    }

    private static func query(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private static func systemCopy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private static func outcome(_ result: (status: OSStatus, data: Data?)) -> Outcome {
        guard result.status == errSecSuccess,
              let data = result.data,
              let text = String(data: data, encoding: .utf8) else {
            return Outcome(payload: nil, status: result.status)
        }
        return Outcome(payload: text, status: result.status)
    }
}

/// A legacy `login.keychain` item carries a **partition list** next to its
/// trusted-application list, and the partition check runs first. A CLI that
/// stores its secret through `/usr/bin/security` — which is how Claude Code
/// writes `Claude Code-credentials` — leaves the item stamped `apple-tool:` and
/// nothing else, so no GUI app is ever inside the partition. Granting "Always
/// Allow" only appends to the trusted-application list, which the partition
/// check never reaches: the item on this machine already trusted four
/// generations of this app and still refused every silent read, which is why
/// Claude quota kept coming from the 20-second PTY screen scrape instead of the
/// official API.
///
/// So read through that same Apple tool: identical item, identical read-only
/// intent, the one path the partition actually admits. The gate below inspects
/// ACL metadata only — it never decrypts — so deciding whether to delegate can
/// never raise a dialog, and delegating only happens once the item's own ACL has
/// said the tool may decrypt it.
extension KeychainRead {
    static let appleToolPath = "/usr/bin/security"
    static let appleToolPartition = "apple-tool:"

    /// The tool itself answers in milliseconds; the timeout exists only so a
    /// wedged read cannot stall a refresh round. It is generous because the gate
    /// has already ruled out the one thing that could block — a dialog — and a
    /// machine busy enough to delay `security` by seconds would otherwise fall
    /// back to the 30-second screen scrape for no reason.
    static func genericPasswordViaAppleTool(
        service: String,
        account: String? = nil,
        timeout: TimeInterval = 8
    ) async -> Outcome {
        guard appleToolMayDecrypt(service: service, account: account) else {
            return Outcome(payload: nil, status: errSecInteractionNotAllowed)
        }
        var arguments = ["find-generic-password", "-w", "-s", service]
        if let account {
            arguments.append(contentsOf: ["-a", account])
        }
        do {
            let data = try await ProcessRunner.run(
                appleToolPath,
                arguments: arguments,
                timeout: timeout
            )
            guard let payload = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
                return Outcome(payload: nil, status: errSecItemNotFound)
            }
            return Outcome(payload: payload, status: errSecSuccess)
        } catch {
            // A timeout also lands here, and `ProcessRunner` has already killed
            // the tool by then. Report it as "needs authorization" so callers
            // keep their existing no-credentials fallback.
            return Outcome(payload: nil, status: errSecInteractionNotAllowed)
        }
    }

    /// True only when this item's own ACL permits `/usr/bin/security` to decrypt
    /// it, its partition list admits Apple tools, and the keychain holding it is
    /// unlocked. All three are metadata reads, so none of them can prompt — and
    /// together they are what makes the delegated read prompt-free too.
    static func appleToolMayDecrypt(service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // A reference is metadata: unlike `kSecReturnData` it never asks
            // securityd to decrypt, so no authorization is evaluated here.
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var reference: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &reference) == errSecSuccess,
              let reference,
              CFGetTypeID(reference) == SecKeychainItemGetTypeID() else {
            return false
        }
        let item = unsafeBitCast(reference, to: SecKeychainItem.self)
        guard isUnlocked(item), let acls = accessControlList(of: item) else { return false }

        var decryptAllowed = false
        // An item without a partition ACL predates the mechanism and is
        // unrestricted by it.
        var partitionAllowed = true
        for acl in acls {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            var applications: CFArray?
            var description: CFString?
            var promptSelector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &promptSelector)
                == errSecSuccess else {
                continue
            }
            if authorizations.contains(kSecACLAuthorizationPartitionID as String) {
                partitionAllowed = partitions(inACLDescription: description as String?)?
                    .contains(appleToolPartition) ?? false
                continue
            }
            guard authorizations.contains(kSecACLAuthorizationDecrypt as String)
                || authorizations.contains(kSecACLAuthorizationAny as String) else {
                continue
            }
            guard let trusted = applications as? [SecTrustedApplication] else {
                // A nil application list means every application may decrypt,
                // in which case the direct read already succeeded.
                decryptAllowed = true
                continue
            }
            if trusted.contains(where: isAppleTool) { decryptAllowed = true }
        }
        return decryptAllowed && partitionAllowed
    }

    /// A locked keychain makes `security` ask for the login password, which is
    /// exactly the dialog automatic refresh must never raise.
    private static func isUnlocked(_ item: SecKeychainItem) -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess,
              let keychain else {
            return false
        }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & kSecUnlockStateStatus != 0
    }

    private static func accessControlList(of item: SecKeychainItem) -> [SecACL]? {
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess,
              let access else {
            return nil
        }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess else { return nil }
        return list as? [SecACL]
    }

    /// The partition ACL keeps its plist in the ACL description, hex-encoded on
    /// current macOS. Accept the plain form too rather than depending on that.
    static func partitions(inACLDescription description: String?) -> [String]? {
        guard let description, !description.isEmpty else { return nil }
        let candidates = [hexDecoded(description), Data(description.utf8)].compactMap { $0 }
        for data in candidates {
            guard let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                continue
            }
            if let partitions = plist["Partitions"] as? [String] { return partitions }
        }
        return nil
    }

    private static func hexDecoded(_ text: String) -> Data? {
        guard text.count % 2 == 0, !text.isEmpty else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
                  let byte = UInt8(text[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func isAppleTool(_ application: SecTrustedApplication) -> Bool {
        var data: CFData?
        guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess,
              let data = data as Data? else {
            return false
        }
        return isAppleTool(trustedApplicationData: data)
    }

    /// The blob is the trusted binary's path with a trailing NUL for the
    /// path-based entries a CLI creates.
    static func isAppleTool(trustedApplicationData data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(appleToolPath)
    }
}

/// go-keyring(gh CLI、Antigravity 等 Go 工具的钥匙串库)会把较长的值
/// 包成 `go-keyring-base64:<b64>`;短值原样存放。
enum GoKeyring {
    static let base64Prefix = "go-keyring-base64:"

    static func unwrap(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(base64Prefix) else {
            return trimmed.isEmpty ? nil : trimmed
        }
        let encoded = String(trimmed.dropFirst(base64Prefix.count))
        guard let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
