import Foundation

// MARK: - CLIResult

struct CLIResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
}

// MARK: - CLIError

enum CLIError: Error, LocalizedError {
    case commandNotFound(String)
    case timeout
    case cancelled
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let cmd): "Command not found: \(cmd)"
        case .timeout: "Process timed out"
        case .cancelled: "Process cancelled"
        case .processError(let msg): msg
        }
    }
}

// MARK: - CLIRunner

/// Wraps Foundation `Process` to run CLI commands asynchronously.
/// Reads stdout/stderr concurrently to prevent pipe-buffer deadlocks.
final class CLIRunner: @unchecked Sendable {

    private final class OutputAccumulator: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// 从用户的登录 shell 中获取完整 PATH（包含 nvm、pyenv、homebrew 等）。
    /// macOS GUI 应用不会继承终端 shell 的环境变量，所以需要主动获取。
    private static let userShellPATH: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // -l: 作为登录 shell 启动，会加载 .zprofile/.zshrc 等配置
        // -i: 交互模式（某些配置只在交互模式下生效）
        // -c: 执行命令后退出
        proc.arguments = ["-l", "-i", "-c", "echo $PATH"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe() // 丢弃 stderr
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }()

    /// 构建完整的进程环境变量，将用户 shell PATH 合并进来
    private static func buildEnvironment(extra: [String: String]?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // 将 shell 中的完整 PATH 注入（保证 nvm、homebrew 等路径可用）
        if let shellPath = userShellPATH {
            let currentPath = env["PATH"] ?? ""
            // 合并去重：shell PATH 优先
            let merged = mergePaths(primary: shellPath, secondary: currentPath)
            env["PATH"] = merged
        }
        if let extra = extra {
            env.merge(extra) { _, new in new }
        }
        return env
    }

    /// 合并两个 PATH 字符串，primary 优先，去除重复路径
    private static func mergePaths(primary: String, secondary: String) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for path in (primary + ":" + secondary).split(separator: ":") {
            let p = String(path)
            if !p.isEmpty && seen.insert(p).inserted {
                result.append(p)
            }
        }
        return result.joined(separator: ":")
    }

    func run(
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        stdinData: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 600,
        shouldTerminate: (@Sendable () async -> Bool)? = nil,
        onOutputChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        // 始终使用增强后的环境变量（包含用户 shell 的完整 PATH）
        process.environment = CLIRunner.buildEnvironment(extra: environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let data = stdinData {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            DispatchQueue.global().async {
                stdinPipe.fileHandleForWriting.write(data)
                stdinPipe.fileHandleForWriting.closeFile()
            }
        }

        do {
            try process.run()
        } catch {
            throw CLIError.processError(error.localizedDescription)
        }

        let stdoutAccumulator = OutputAccumulator()
        let stderrAccumulator = OutputAccumulator()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutAccumulator.append(data)
            if let onOutputChunk, let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                onOutputChunk(chunk)
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrAccumulator.append(data)
            if let onOutputChunk, let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                onOutputChunk(chunk)
            }
        }

        enum TerminationReason {
            case normal, timeout, cancelled
        }
        var terminationReason: TerminationReason = .normal
        let startedAt = Date()

        while process.isRunning {
            if Task.isCancelled {
                terminationReason = .cancelled
                process.terminate()
                break
            }

            if let shouldTerminate, await shouldTerminate() {
                terminationReason = .cancelled
                process.terminate()
                break
            }

            if Date().timeIntervalSince(startedAt) >= timeout {
                terminationReason = .timeout
                process.terminate()
                break
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        process.waitUntilExit()
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        let remainingStdout = stdoutHandle.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutAccumulator.append(remainingStdout)
            if let onOutputChunk, let chunk = String(data: remainingStdout, encoding: .utf8), !chunk.isEmpty {
                onOutputChunk(chunk)
            }
        }

        let remainingStderr = stderrHandle.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrAccumulator.append(remainingStderr)
            if let onOutputChunk, let chunk = String(data: remainingStderr, encoding: .utf8), !chunk.isEmpty {
                onOutputChunk(chunk)
            }
        }

        let stdout = String(data: stdoutAccumulator.value(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrAccumulator.value(), encoding: .utf8) ?? ""

        if terminationReason == .timeout {
            throw CLIError.timeout
        }
        if terminationReason == .cancelled {
            throw CLIError.cancelled
        }

        return CLIResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}
