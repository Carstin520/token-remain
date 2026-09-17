import Darwin
import Foundation

/// Owns only the CLI process started for an explicit account login. Output is
/// drained while the process runs; terminal paint and OAuth URLs are discarded.
enum AccountLoginProcessRunner {
    static let loginTimeout: TimeInterval = 300
    static let statusTimeout: TimeInterval = 15

    enum Failure: LocalizedError {
        case timedOut
        case exited(Int32)
        case outputLimitExceeded

        var errorDescription: String? {
            switch self {
            case .timedOut: L10n.text("accounts.login_timed_out")
            case .exited, .outputLimitExceeded: L10n.text("accounts.setup.failed")
            }
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        usesTerminal: Bool = false,
        capturesOutput: Bool = false,
        mergesStandardError: Bool = false,
        timeout: TimeInterval
    ) async throws -> Data {
        try Task.checkCancellation()
        // The worker alone owns Process and its descriptors. Explicitly forward
        // cancellation: awaiting a detached task does not do this automatically.
        let worker = Task.detached(priority: .userInitiated) {
            try execute(
                executable: executable, arguments: arguments, environment: environment,
                usesTerminal: usesTerminal, capturesOutput: capturesOutput,
                mergesStandardError: mergesStandardError, timeout: timeout
            )
        }
        return try await withTaskCancellationHandler {
            let output = try await worker.value
            try Task.checkCancellation()
            return output
        } onCancel: {
            worker.cancel()
        }
    }

    private static func execute(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        usesTerminal: Bool,
        capturesOutput: Bool,
        mergesStandardError: Bool,
        timeout: TimeInterval
    ) throws -> Data {
        try Task.checkCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var reader: Int32 = -1
        var writer: Int32 = -1
        if usesTerminal {
            var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&reader, &writer, nil, nil, &size) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            reader = descriptors[0]
            writer = descriptors[1]
        }
        // Both ends must close even when Process.run() throws.
        defer {
            Darwin.close(reader)
            if writer >= 0 { Darwin.close(writer) }
        }
        let flags = fcntl(reader, F_GETFL)
        guard flags >= 0, fcntl(reader, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let outputHandle = FileHandle(fileDescriptor: writer, closeOnDealloc: false)
        process.standardInput = usesTerminal ? outputHandle : FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = usesTerminal || mergesStandardError ? outputHandle : FileHandle.nullDevice
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
        try process.run()
        defer { stopIfRunning(process) }
        Darwin.close(writer)
        writer = -1

        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
            let hasExited = !process.isRunning
            var drained = false
            // Bound each pass so a child writing continuously cannot starve
            // cancellation or the deadline. Poll waits only when no bytes exist.
            for _ in 0..<32 {
                let count = Darwin.read(reader, &bytes, bytes.count)
                if count > 0 {
                    if capturesOutput {
                        guard output.count + count <= 1_048_576 else { throw Failure.outputLimitExceeded }
                        output.append(contentsOf: bytes.prefix(count))
                    }
                } else {
                    if count < 0, errno == EINTR { continue }
                    guard count == 0 || errno == EAGAIN || errno == EWOULDBLOCK
                            || (usesTerminal && errno == EIO) else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    drained = true
                    break
                }
            }
            if hasExited, drained {
                process.waitUntilExit()
                try Task.checkCancellation()
                guard process.terminationStatus == 0 else { throw Failure.exited(process.terminationStatus) }
                return output
            }
            if drained {
                var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 20)
                // EOF/HUP is immediately readable while Foundation reports exit.
                if descriptor.revents & Int16(POLLHUP) != 0 { usleep(1_000) }
            }
        }
    }

    private static func stopIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        _ = Darwin.kill(pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        process.waitUntilExit()
    }
}
