import Foundation

// MARK: - StepResult

struct StepResult: Sendable {
    let stepID: UUID
    let exitCode: Int32
    let output: String
    let error: String
    let cancelledByUser: Bool

    init(
        stepID: UUID,
        exitCode: Int32,
        output: String,
        error: String,
        cancelledByUser: Bool = false
    ) {
        self.stepID = stepID
        self.exitCode = exitCode
        self.output = output
        self.error = error
        self.cancelledByUser = cancelledByUser
    }

    var succeeded: Bool { exitCode == 0 }
    var failed: Bool { !succeeded && !cancelledByUser }

    var displayOutput: String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedError = error.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedOutput.isEmpty {
            return trimmedError
        }

        if trimmedError.isEmpty || trimmedOutput.contains("[STDERR]") {
            return trimmedOutput
        }

        return """
        \(trimmedOutput)

        [STDERR]
        \(trimmedError)
        """
    }
}

// MARK: - ToolRunner Protocol

protocol ToolRunner: Sendable {
    var toolType: ToolType { get }
    func execute(
        step: PipelineStep,
        workingDirectory: String,
        shouldTerminate: (@Sendable () async -> Bool)?,
        onOutputChunk: (@Sendable (String) -> Void)?
    ) async throws -> StepResult
}

extension ToolRunner {
    func execute(step: PipelineStep, workingDirectory: String) async throws -> StepResult {
        try await execute(
            step: step,
            workingDirectory: workingDirectory,
            shouldTerminate: nil,
            onOutputChunk: nil
        )
    }
}
