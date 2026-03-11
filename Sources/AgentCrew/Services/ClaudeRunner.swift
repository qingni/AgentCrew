import Foundation

/// Runs a pipeline step via the Anthropic Claude CLI.
///
/// Command pattern:
///   claude --print --permission-mode bypassPermissions --add-dir <dir> < prompt
struct ClaudeRunner: ToolRunner {
    let toolType: ToolType = .claude
    private let cli = CLIRunner()

    func execute(
        step: PipelineStep,
        workingDirectory: String,
        shouldTerminate: (@Sendable () async -> Bool)?,
        onOutputChunk: (@Sendable (String) -> Void)?
    ) async throws -> StepResult {
        var args = [
            "--print",
            "--permission-mode", "bypassPermissions",
            "--add-dir", workingDirectory,
        ]
        if let model = step.model {
            args += ["--model", model]
        }

        let result = try await cli.run(
            command: "claude",
            arguments: args,
            stdinData: step.prompt.data(using: .utf8),
            shouldTerminate: shouldTerminate,
            onOutputChunk: onOutputChunk
        )
        return StepResult(stepID: step.id, exitCode: result.exitCode, output: result.stdout, error: result.stderr)
    }
}
