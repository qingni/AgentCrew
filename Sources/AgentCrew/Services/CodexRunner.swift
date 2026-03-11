import Foundation

/// Runs a pipeline step via the OpenAI Codex CLI.
///
/// Command pattern:
///   codex-internal exec --sandbox workspace-write --skip-git-repo-check "<prompt>"
struct CodexRunner: ToolRunner {
    let toolType: ToolType = .codex
    private let cli = CLIRunner()

    func execute(
        step: PipelineStep,
        workingDirectory: String,
        shouldTerminate: (@Sendable () async -> Bool)?,
        onOutputChunk: (@Sendable (String) -> Void)?
    ) async throws -> StepResult {
        var args = [
            "exec",
            "--sandbox", "workspace-write",
            "--skip-git-repo-check",
        ]
        if let model = step.model {
            args += ["--model", model]
        }
        if !step.prompt.isEmpty {
            args.append(step.prompt)
        }

        let result = try await cli.run(
            command: "codex-internal",
            arguments: args,
            workingDirectory: workingDirectory,
            shouldTerminate: shouldTerminate,
            onOutputChunk: onOutputChunk
        )
        return StepResult(stepID: step.id, exitCode: result.exitCode, output: result.stdout, error: result.stderr)
    }
}
