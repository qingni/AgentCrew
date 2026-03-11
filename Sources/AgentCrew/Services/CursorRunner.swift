import Foundation

/// Runs a pipeline step via the Cursor CLI agent.
///
/// Command pattern:
///   agent --trust --model opus-4.6 -p "<prompt>"
struct CursorRunner: ToolRunner {
    let toolType: ToolType = .cursor
    private let cli = CLIRunner()

    func execute(
        step: PipelineStep,
        workingDirectory: String,
        shouldTerminate: (@Sendable () async -> Bool)?,
        onOutputChunk: (@Sendable (String) -> Void)?
    ) async throws -> StepResult {
        let resolvedModel: String
        if let model = step.model, !model.isEmpty {
            resolvedModel = model
        } else {
            resolvedModel = ToolType.defaultCursorModel
        }

        let args = ["--trust", "--model", resolvedModel, "-p", step.prompt]
        let result = try await cli.run(
            command: "agent",
            arguments: args,
            workingDirectory: workingDirectory,
            shouldTerminate: shouldTerminate,
            onOutputChunk: onOutputChunk
        )
        return StepResult(stepID: step.id, exitCode: result.exitCode, output: result.stdout, error: result.stderr)
    }
}
