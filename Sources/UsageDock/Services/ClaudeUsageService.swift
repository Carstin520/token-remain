import Darwin
import Foundation
import OSLog

struct ClaudeUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case cliNotFound
        case cliTimedOut
        case cliLaunchFailed(String)
        case invalidUsageOutput
        case rateLimited(retryAfterSeconds: Int?)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "未找到 Claude Code；请先安装并登录 Claude Code"
            case .cliTimedOut:
                return "Claude Code 用量读取超时，正在显示最近缓存"
            case .cliLaunchFailed(let detail):
                return "无法启动 Claude Code 用量探针：\(detail)"
            case .invalidUsageOutput:
                return "Claude Code 未返回可识别的 5 小时 / 7 天用量"
            case .rateLimited(let seconds):
                if let seconds {
                    return "Claude 用量接口限流，约 \(max(1, Int((Double(seconds) / 60).rounded(.up)))) 分钟后自动重试"
                }
                return "Claude 用量接口限流，稍后自动重试"
            }
        }

        var retryDelay: TimeInterval {
            if case .rateLimited(let seconds) = self, let seconds {
                return max(60, TimeInterval(seconds))
            }
            return 300
        }
    }

    /// 主路径:oauth/usage API 直查(只读 Claude Code 凭证,秒级返回)。
    /// 凭证缺失/过期/被拒或响应异常时降级 PTY `/usage` 探针——探针会让
    /// Claude Code 自行完成续期,下一轮 API 直查即可恢复。
    /// 服务端明确限流(429)时不降级:PTY 的 /usage 走同一个接口,
    /// 换个马甲重试只会延长限流。
    func fetch() async throws -> ProviderQuota {
        let logger = Logger(subsystem: "com.jamesli.usagedock", category: "ClaudeUsage")
        do {
            let quota = try await ClaudeOAuthUsageService().fetch()
            logger.info("Claude quota served by oauth/usage API")
            return quota
        } catch let error as ClaudeOAuthUsageService.APIError {
            if case .rateLimited(let seconds) = error {
                throw ServiceError.rateLimited(retryAfterSeconds: seconds)
            }
            logger.info("Claude API path unavailable (\(error.localizedDescription, privacy: .public)); falling back to PTY probe")
        } catch {
            // 网络层错误(离线、超时)同样交给 PTY 兜底。
            logger.info("Claude API path failed (\(error.localizedDescription, privacy: .public)); falling back to PTY probe")
        }
        let output = try await ClaudeCLIUsageProbe.run()
        return try ClaudeCLIUsageParser.parse(output)
    }
}

enum ClaudeCLIUsageParser {
    private struct PercentReading {
        let usedPercent: Double
    }

    static func parse(_ data: Data, now: Date = .now, calendar: Calendar = .current) throws -> ProviderQuota {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ClaudeUsageService.ServiceError.invalidUsageOutput
        }
        let text = cleanedTerminalText(raw)
        let readings = percentReadings(in: text)
        guard readings.count >= 2 else {
            throw ClaudeUsageService.ServiceError.invalidUsageOutput
        }

        let resetDescriptions = resetDescriptions(in: text)
        // Terminal repainting can reorder or omit rows. Match reset values by
        // shape instead of array position: session resets are time-only, while
        // weekly resets include a month and day.
        let primaryReset = resetDescriptions
            .first(where: { !containsMonth($0) })
            .flatMap { parseResetDate($0, now: now, calendar: calendar) }
        let secondaryReset = resetDescriptions
            .first(where: containsMonth)
            .flatMap { parseResetDate($0, now: now, calendar: calendar) }
        return ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(
                usedPercent: readings[0].usedPercent,
                windowMinutes: 300,
                resetsAt: primaryReset
            ),
            secondary: QuotaWindow(
                usedPercent: readings[1].usedPercent,
                windowMinutes: 10_080,
                resetsAt: secondaryReset
            ),
            planName: nil,
            capturedAt: now
        )
    }

    static func hasCompleteUsage(in data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8) else { return false }
        let text = cleanedTerminalText(raw)
        return percentReadings(in: text).count >= 2 && resetDescriptions(in: text).count >= 2
    }

    private static func cleanedTerminalText(_ raw: String) -> String {
        let escape = "\u{001B}"
        var text = raw
        text = text.replacingOccurrences(
            of: "\(escape)\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\(escape)\\][^\u{0007}]*(?:\u{0007}|\(escape)\\\\)",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\u{0008}", with: "")
        return text
    }

    private static func percentReadings(in text: String) -> [PercentReading] {
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*(used|left|remaining)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let directionRange = Range(match.range(at: 2), in: text),
                  let number = Double(text[numberRange]) else {
                return nil
            }
            let direction = text[directionRange].lowercased()
            let used = direction == "used" ? number : 100 - number
            return PercentReading(usedPercent: min(100, max(0, used)))
        }
    }

    private static func resetDescriptions(in text: String) -> [String] {
        let pattern = #"resets?\s*([^\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let value = text[range]
                .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private static func parseResetDate(_ description: String, now: Date, calendar sourceCalendar: Calendar) -> Date? {
        let calendar = sourceCalendar
        let compact = description
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse the more specific month/day form first. A value such as
        // "Jul 24 at 1pm" also contains a valid time-only substring; matching
        // that first would silently turn the weekly reset into tomorrow at 1pm.
        if let match = firstMatch(
            #"\b([A-Za-z]{3,9})\s+(\d{1,2})(?:\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?\b"#,
            in: compact
        ), let monthText = capture(1, from: match, in: compact),
           let dayText = capture(2, from: match, in: compact),
           let month = monthNumber(monthText) {
            var components = calendar.dateComponents([.year], from: now)
            components.month = month
            components.day = Int(dayText)
            components.minute = capture(4, from: match, in: compact).flatMap(Int.init) ?? 0
            components.second = 0

            var hour = capture(3, from: match, in: compact).flatMap(Int.init) ?? 0
            let meridiem = capture(5, from: match, in: compact)?.lowercased()
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
            components.hour = hour

            guard var date = calendar.date(from: components) else { return nil }
            if date <= now {
                date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
            }
            return date
        }

        if let match = firstMatch(#"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, in: compact),
           let hourText = capture(1, from: match, in: compact) {
            var hour = Int(hourText) ?? 0
            let minute = capture(2, from: match, in: compact).flatMap(Int.init) ?? 0
            let meridiem = capture(3, from: match, in: compact)?.lowercased()
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }

            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard var date = calendar.date(from: components) else { return nil }
            if date <= now {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return date
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func capture(_ index: Int, from match: NSTextCheckingResult, in text: String) -> String? {
        let nsRange = match.range(at: index)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }

    private static func monthNumber(_ value: String) -> Int? {
        let prefix = value.lowercased().prefix(3)
        return [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4,
            "may": 5, "jun": 6, "jul": 7, "aug": 8,
            "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ][String(prefix)]
    }

    private static func containsMonth(_ text: String) -> Bool {
        let pattern = #"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[A-Za-z]*\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private enum ClaudeCLIUsageProbe {
    static func run(timeout: TimeInterval = 30) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard let executable = claudeExecutable() else {
                throw ClaudeUsageService.ServiceError.cliNotFound
            }
            let probeDirectory = try prepareProbeDirectory()

            var master: Int32 = -1
            var slave: Int32 = -1
            // Claude Code's /usage overlay is optimized for a standard terminal.
            // Very wide PTYs can emit the session percentage before the reset rows
            // finish rendering, while 80 columns consistently paints both windows.
            var windowSize = winsize(ws_row: 60, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
                throw ClaudeUsageService.ServiceError.cliLaunchFailed(String(cString: strerror(errno)))
            }
            defer { Darwin.close(master) }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["--allowed-tools", ""]
            process.currentDirectoryURL = probeDirectory
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment["PATH"] = pathWithClaudeHints(environment["PATH"])
            process.environment = environment

            let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            process.standardInput = terminal
            process.standardOutput = terminal
            process.standardError = terminal

            do {
                try process.run()
            } catch {
                Darwin.close(slave)
                throw ClaudeUsageService.ServiceError.cliLaunchFailed(error.localizedDescription)
            }
            Darwin.close(slave)

            let flags = fcntl(master, F_GETFL)
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

            var output = Data()
            let startedAt = Date()
            var sentUsage = false
            var lastInputAt = Date.distantPast
            var completedAt: Date?

            while process.isRunning && Date().timeIntervalSince(startedAt) < timeout {
                readAvailable(from: master, into: &output)
                let now = Date()
                let elapsed = now.timeIntervalSince(startedAt)

                if !sentUsage && elapsed >= 5 {
                    write("/usage\r", to: master)
                    sentUsage = true
                    lastInputAt = now
                } else if now.timeIntervalSince(lastInputAt) >= 0.8 {
                    write("\r", to: master)
                    lastInputAt = now
                }

                if sentUsage && ClaudeCLIUsageParser.hasCompleteUsage(in: output) {
                    if completedAt == nil { completedAt = now }
                    if now.timeIntervalSince(completedAt!) >= 1.2 { break }
                }
                usleep(80_000)
            }

            readAvailable(from: master, into: &output)
            stop(process, terminal: master)
            readAvailable(from: master, into: &output)

            guard ClaudeCLIUsageParser.hasCompleteUsage(in: output) else {
                if Date().timeIntervalSince(startedAt) >= timeout {
                    throw ClaudeUsageService.ServiceError.cliTimedOut
                }
                throw ClaudeUsageService.ServiceError.invalidUsageOutput
            }
            return output
        }.value
    }

    private static func claudeExecutable() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["USAGEDOCK_CLAUDE_COMMAND"], !override.isEmpty {
            candidates.append(override)
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ])
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/claude" })
        }
        guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func prepareProbeDirectory() throws -> URL {
        let fileManager = FileManager.default
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = caches.appendingPathComponent("com.jamesli.usagedock/claude-probe", isDirectory: true)
        let settingsDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        try fileManager.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)

        let settings = settingsDirectory.appendingPathComponent("settings.local.json")
        if !fileManager.fileExists(atPath: settings.path) {
            let data = Data(#"{"disableDeepLinkRegistration":"disable"}"#.utf8)
            try data.write(to: settings, options: .atomic)
        }
        return root
    }

    private static func pathWithClaudeHints(_ existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hints = [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let current = existing?.split(separator: ":").map(String.init) ?? []
        return Array(NSOrderedSet(array: hints + current)).compactMap { $0 as? String }.joined(separator: ":")
    }

    private static func readAvailable(from descriptor: Int32, into data: inout Data) {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(Int(count)))
            } else {
                break
            }
        }
    }

    private static func write(_ text: String, to descriptor: Int32) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(descriptor, baseAddress, buffer.count)
        }
    }

    private static func stop(_ process: Process, terminal descriptor: Int32) {
        write("/exit\r", to: descriptor)
        waitForExit(process, seconds: 0.5)
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
            waitForExit(process, seconds: 0.5)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            waitForExit(process, seconds: 0.5)
        }
        if !process.isRunning {
            process.waitUntilExit()
        }
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            usleep(25_000)
        }
    }
}
