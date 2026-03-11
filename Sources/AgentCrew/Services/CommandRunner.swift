import Foundation

/// Runs a pipeline step using a user-provided shell command.
///
/// If the command contains `{{prompt}}`, the prompt is shell-escaped and
/// inlined into the command. Otherwise the prompt is sent to stdin.
struct CommandRunner: Sendable {
    private let cli = CLIRunner()
    private let resolvableExecutables: Set<String> = [
        "codex-internal",
        "claude-internal",
        "agent",
        "codex",
        "claude",
    ]

    func execute(
        step: PipelineStep,
        workingDirectory: String,
        shouldTerminate: (@Sendable () async -> Bool)? = nil,
        onOutputChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> StepResult {
        let commandLine = step.effectiveCommand
        guard !commandLine.isEmpty else {
            throw CLIError.processError("Step command is empty")
        }

        let prompt = step.prompt
        let stdinData: Data?
        let finalCommand: String

        if commandLine.contains("{{prompt}}") {
            finalCommand = commandLine.replacingOccurrences(
                of: "{{prompt}}",
                with: shellQuote(prompt)
            )
            stdinData = nil
        } else {
            finalCommand = commandLine
            stdinData = prompt.isEmpty ? nil : prompt.data(using: .utf8)
        }

        let resolution = await resolveCommandLine(finalCommand)

        let result = try await cli.run(
            command: "zsh",
            arguments: ["-lc", resolution.commandLine],
            workingDirectory: workingDirectory,
            stdinData: stdinData,
            shouldTerminate: shouldTerminate,
            onOutputChunk: onOutputChunk
        )

        let output = formattedOutput(
            originalCommand: commandLine,
            resolution: resolution,
            workingDirectory: workingDirectory,
            result: result
        )

        return StepResult(
            stepID: step.id,
            exitCode: result.exitCode,
            output: output,
            error: formattedError(result)
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func resolveCommandLine(_ commandLine: String) async -> CommandResolution {
        guard let executable = leadingExecutable(in: commandLine),
              resolvableExecutables.contains(executable),
              let resolvedPath = await resolveExecutablePath(executable)
        else {
            return CommandResolution(
                commandLine: commandLine,
                executable: leadingExecutable(in: commandLine),
                resolvedExecutablePath: nil
            )
        }

        return CommandResolution(
            commandLine: replacingLeadingExecutable(in: commandLine, with: shellQuote(resolvedPath)),
            executable: executable,
            resolvedExecutablePath: resolvedPath
        )
    }

    private func leadingExecutable(in commandLine: String) -> String? {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let token = String(trimmed.prefix { !$0.isWhitespace })
        guard !token.isEmpty, !token.contains("/") else { return nil }
        return token
    }

    private func replacingLeadingExecutable(in commandLine: String, with replacement: String) -> String {
        let leadingWhitespace = commandLine.prefix { $0.isWhitespace }
        let trimmed = commandLine.drop(while: \.isWhitespace)
        let executable = trimmed.prefix { !$0.isWhitespace }
        let rest = trimmed.dropFirst(executable.count)
        return String(leadingWhitespace) + replacement + rest
    }

    private func resolveExecutablePath(_ executable: String) async -> String? {
        do {
            let result = try await cli.run(
                command: "zsh",
                arguments: ["-lc", "command -v \(shellQuote(executable)) 2>/dev/null"],
                timeout: 10
            )

            let path = result.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last(where: { $0.hasPrefix("/") })?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let path else { return nil }
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    private func formattedOutput(
        originalCommand: String,
        resolution: CommandResolution,
        workingDirectory: String,
        result: CLIResult
    ) -> String {
        guard result.exitCode != 0 else {
            return result.stdout
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        Command failed.

        [Original Command]
        \(originalCommand)

        [Executed Command]
        \(resolution.commandLine)

        [Working Directory]
        \(workingDirectory)

        [Resolved Executable]
        \(resolution.resolvedExecutablePath ?? "Not resolved")

        [Exit Code]
        \(result.exitCode)

        [STDOUT]
        \(stdout.isEmpty ? "(empty)" : stdout)

        [STDERR]
        \(stderr.isEmpty ? "(empty)" : stderr)
        """
    }

    private func formattedError(_ result: CLIResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }
        return "Command exited with code \(result.exitCode)"
    }
}

private struct CommandResolution: Sendable {
    let commandLine: String
    let executable: String?
    let resolvedExecutablePath: String?
}
