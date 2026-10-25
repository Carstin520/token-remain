import Darwin
import Foundation

/// DeepSeek Harness(`dsh`)把 DeepSeek 开放平台 Key 存在
/// `$DSH_HOME/.credentials.yaml`(默认 `~/.dsh`)的 `refs.DEEPSEEK_API_KEY`。
/// 凭证归 DSH 所有:只读、不写回、不缓存,值只在单次余额请求里使用。
///
/// DSH 可以把 DeepSeek 路由改到中转站(`DEEPSEEK_BASE_URL`,或 home/profile
/// 级 `cordis.patch.yml` 里 llm-deepseek 条目的 `baseURL`),那时这把 Key
/// 属于中转站,不能发往 api.deepseek.com。检测到任何覆写、文件超限或无法
/// 读取判断时一律放弃,交给手动 Key 流程。项目级 `.env`(启动 dsh 时的
/// cwd)无从得知,不在检查范围内。
struct DeepSeekHarnessCredentialReader {
    static let homeEnvironmentKey = "DSH_HOME"
    static let baseURLEnvironmentKey = "DEEPSEEK_BASE_URL"
    static let credentialRef = "DEEPSEEK_API_KEY"
    static let maxFileBytes = 256 * 1024
    static let maxProfiles = 64

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    /// 与 DSH 的 `resolveDshHome` 同口径:非空 `$DSH_HOME` 优先(展开 `~`),
    /// 空白值视为未设置,否则 `~/.dsh`。
    var dshHome: URL {
        if let override = environment[Self.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appending(path: ".dsh", directoryHint: .isDirectory)
    }

    var credentialsURL: URL { dshHome.appending(path: ".credentials.yaml") }

    func load() -> String? {
        guard !hasEndpointOverride,
              case .contents(let data) = Self.readFile(credentialsURL) else { return nil }
        return Self.apiKey(fromCredentialsYAML: String(decoding: data, as: UTF8.self))
    }

    /// Whether a DSH key is usable, for detection; never returns the key.
    var isAvailable: Bool { load() != nil }

    var hasEndpointOverride: Bool {
        if environment[Self.baseURLEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        switch Self.readFile(dshHome.appending(path: ".env")) {
        case .missing: break
        case .unreadable: return true
        case .contents(let data):
            if Self.dotenvSetsBaseURL(String(decoding: data, as: UTF8.self)) { return true }
        }
        guard let patches = patchFiles else { return true }
        for url in patches {
            switch Self.readFile(url) {
            case .missing: continue
            case .unreadable: return true
            case .contents(let data):
                if Self.patchOverridesBaseURL(String(decoding: data, as: UTF8.self)) { return true }
            }
        }
        return false
    }

    /// home 级 patch 加上每个 `profiles/<name>/cordis.patch.yml`。profiles
    /// 目录存在却列不出、或数量异常时返回 nil,由调用方按覆写处理。
    var patchFiles: [URL]? {
        var files = [dshHome.appending(path: "cordis.patch.yml")]
        let profiles = dshHome.appending(path: "profiles", directoryHint: .isDirectory)
        var profileStatus = stat()
        if lstat(profiles.path, &profileStatus) != 0 {
            return errno == ENOENT ? files : nil
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: profiles.path),
              names.count <= Self.maxProfiles else { return nil }
        files += names.sorted().map { profiles.appending(path: $0).appending(path: "cordis.patch.yml") }
        return files
    }

    enum FileRead: Equatable {
        case missing
        case unreadable
        case contents(Data)
    }

    static func readFile(_ url: URL) -> FileRead {
        // fileExists follows links and reports an unreadable/dangling override
        // as absent. Inspect the entry first, then read the opened regular file
        // with a byte limit. Nonblocking open also prevents a FIFO from hanging
        // a credential check before its request deadline can take effect.
        var entry = stat()
        guard lstat(url.path, &entry) == 0 else {
            return errno == ENOENT ? .missing : .unreadable
        }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_size <= maxFileBytes else { return .unreadable }
        do {
            let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
            guard data.count <= maxFileBytes else { return .unreadable }
            return .contents(data)
        } catch {
            return .unreadable
        }
    }

    // MARK: - Parsing

    /// 只认 DSH 文档的 `version: 1` 形态:顶层 `refs:` 下的块映射,值是单行
    /// 纯量(plain / 单引号 / 双引号)。块纯量、流式写法、锚点、重复键、
    /// 未知版本都放弃——宁可回到手动 Key,也不猜一个可能错的值。
    static func apiKey(fromCredentialsYAML text: String) -> String? {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var version: String?
        var refsStart: Int?
        for (index, line) in lines.enumerated() {
            guard let first = line.first, first != " ", first != "#" else { continue }
            if first == "\t" { return nil }
            guard let (key, value) = mappingEntry(line) else { continue }
            switch key {
            case "version":
                guard version == nil else { return nil }
                version = scalar(value)
            case "refs":
                guard refsStart == nil, stripComment(value).isEmpty else { return nil }
                refsStart = index + 1
            default:
                continue
            }
        }
        guard version == "1", let refsStart else { return nil }

        var childIndent: Int?
        var found: String?
        for line in lines[refsStart...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.hasPrefix("\t") { return nil }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 { break }
            if childIndent == nil { childIndent = indent }
            guard indent == childIndent,
                  let (key, value) = mappingEntry(String(line.dropFirst(indent))),
                  key == credentialRef else { continue }
            guard found == nil, let parsed = scalar(value) else { return nil }
            found = parsed
        }
        guard let found, !found.isEmpty,
              found.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else {
            return nil
        }
        return found
    }

    /// `key: value` 拆分;键可带引号。不是映射行时返回 nil。
    private static func mappingEntry(_ line: String) -> (String, String)? {
        if let quote = line.first, quote == "'" || quote == "\"" {
            let body = line.dropFirst()
            guard let close = body.firstIndex(of: quote) else { return nil }
            let rest = body[body.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            return (String(body[..<close]), String(rest.dropFirst()))
        }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let after = line[line.index(after: colon)...]
        guard after.isEmpty || after.first == " " else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, String(after))
    }

    private static func scalar(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard let first = value.first else { return nil }
        switch first {
        case "'":
            var result = ""
            var index = value.index(after: value.startIndex)
            while index < value.endIndex {
                let character = value[index]
                index = value.index(after: index)
                guard character == "'" else { result.append(character); continue }
                if index < value.endIndex, value[index] == "'" {
                    result.append("'")
                    index = value.index(after: index)
                    continue
                }
                return stripComment(String(value[index...])).isEmpty ? result : nil
            }
            return nil
        case "\"":
            var result = ""
            var index = value.index(after: value.startIndex)
            while index < value.endIndex {
                let character = value[index]
                index = value.index(after: index)
                if character == "\\" {
                    guard index < value.endIndex, value[index] == "\"" || value[index] == "\\" else { return nil }
                    result.append(value[index])
                    index = value.index(after: index)
                } else if character == "\"" {
                    return stripComment(String(value[index...])).isEmpty ? result : nil
                } else {
                    result.append(character)
                }
            }
            return nil
        case "|", ">", "&", "*", "!", "{", "[", "%", "@", "`":
            return nil
        default:
            let plain = stripComment(value)
            return plain.isEmpty ? nil : plain
        }
    }

    /// YAML 纯量里的注释以「空白 + #」开头。
    private static func stripComment(_ value: String) -> String {
        var previous: Character = " "
        for index in value.indices {
            if value[index] == "#", previous == " " || previous == "\t" {
                return value[..<index].trimmingCharacters(in: .whitespaces)
            }
            previous = value[index]
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    static func dotenvSetsBaseURL(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == baseURLEnvironmentKey else { return false }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return !value.isEmpty
        }
    }

    /// patch 是 YAML 列表:按顶层 `-` 条目切块,任何同时提到 llm-deepseek
    /// 与 `baseURL` 键的条目都算覆写(含被注释掉的行,宁可误判)。
    static func patchOverridesBaseURL(_ text: String) -> Bool {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("-"), !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        chunks.append(current)
        return chunks.contains { chunk in
            let lowered = chunk.lowercased()
            return lowered.contains("llm-deepseek")
                && lowered.range(of: #"baseurl['"]?\s*:"#, options: .regularExpression) != nil
        }
    }
}
