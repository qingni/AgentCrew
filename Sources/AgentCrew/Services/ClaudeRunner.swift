import Foundation

/// Runs a pipeline step via the Claude CLI, configured through CLIProfile.
struct ClaudeRunner: ToolRunner {
    let toolType: ToolType = .claude
    private let cli = CLIRunner()

    func execute(
        step: PipelineStep,
        workingDirectory: String,
        shouldTerminate: (@Sendable () async -> Bool)?,
        onOutputChunk: (@Sendable (String) -> Void)?
    ) async throws -> StepResult {
        let config = ProfileStore.current().config(for: .claude)
        let args = config.buildArguments(
            prompt: step.prompt,
            model: step.model,
            workingDirectory: workingDirectory
        )

        let result = try await cli.run(
            command: config.executable,
            arguments: args,
            workingDirectory: workingDirectory,
            stdinData: config.promptMode == .stdin ? step.prompt.data(using: .utf8) : nil,
            shouldTerminate: shouldTerminate,
            onOutputChunk: onOutputChunk
        )
        return StepResult(stepID: step.id, exitCode: result.exitCode, output: result.stdout, error: result.stderr)
    }
}
