import Foundation

// MARK: - SchedulerError

enum SchedulerError: Error, LocalizedError {
    case cyclicDependency
    case stepFailed(StepResult)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cyclicDependency:
            "Pipeline contains cyclic dependencies"
        case .stepFailed(let r):
            "Step failed (exit code \(r.exitCode)): \(r.error)"
        case .cancelled:
            "Pipeline execution was cancelled"
        }
    }
}

// MARK: - ExecutionControl

actor ExecutionControl {
    private var pipelineStopRequested = false
    private var stoppedStageIDs: Set<UUID> = []

    func requestPipelineStop() {
        pipelineStopRequested = true
    }

    func requestStageStop(_ stageID: UUID) {
        stoppedStageIDs.insert(stageID)
    }

    func isPipelineStopRequested() -> Bool {
        pipelineStopRequested
    }

    func isStageStopRequested(_ stageID: UUID) -> Bool {
        stoppedStageIDs.contains(stageID)
    }

    func shouldTerminateStep(in stageID: UUID) -> Bool {
        pipelineStopRequested || stoppedStageIDs.contains(stageID)
    }
}

// MARK: - DAGScheduler

/// Executes a Pipeline using DAG topological-sort + wave-parallel scheduling.
///
/// Within each wave, all ready steps run concurrently via `TaskGroup`.
/// Waves execute sequentially, waiting for all steps in the current wave
/// before computing the next one.
final class DAGScheduler: @unchecked Sendable {

    func executePipeline(
        _ pipeline: Pipeline,
        executionControl: ExecutionControl? = nil,
        onStepStatusChanged: @escaping @Sendable (UUID, StepStatus) -> Void,
        onStepOutput: @escaping @Sendable (UUID, String) -> Void
    ) async throws -> [StepResult] {
        let allSteps = pipeline.allStepsWithResolvedDependencies()
        try Self.validateDAG(allSteps)

        let stepsByID = Dictionary(uniqueKeysWithValues: allSteps.map { ($0.step.id, $0.step) })
        var finalizedStatuses: [UUID: StepStatus] = [:]
        var allResults: [StepResult] = []
        let workDir = pipeline.workingDirectory

        while finalizedStatuses.count < allSteps.count {
            if await executionControl?.isPipelineStopRequested() == true {
                for resolved in allSteps where finalizedStatuses[resolved.step.id] == nil {
                    finalizedStatuses[resolved.step.id] = .skipped
                    onStepStatusChanged(resolved.step.id, .skipped)
                }
                throw SchedulerError.cancelled
            }

            let ready = allSteps.filter { resolved in
                finalizedStatuses[resolved.step.id] == nil
                    && resolved.allDependencies.allSatisfy { finalizedStatuses[$0] != nil }
            }
            guard !ready.isEmpty else {
                throw SchedulerError.cyclicDependency
            }

            var wave: [ResolvedStep] = []
            var skippedAnyReadyStep = false

            for resolved in ready {
                if await executionControl?.isStageStopRequested(resolved.stageID) == true {
                    finalizedStatuses[resolved.step.id] = .skipped
                    onStepStatusChanged(resolved.step.id, .skipped)
                    skippedAnyReadyStep = true
                    continue
                }

                let blockedByDependency = resolved.allDependencies.contains { dependencyID in
                    let dependencyStatus = finalizedStatuses[dependencyID] ?? .pending
                    return dependencyStatus != .completed
                }
                if blockedByDependency {
                    finalizedStatuses[resolved.step.id] = .skipped
                    onStepStatusChanged(resolved.step.id, .skipped)
                    skippedAnyReadyStep = true
                    continue
                }

                wave.append(resolved)
            }

            if wave.isEmpty {
                if skippedAnyReadyStep {
                    continue
                }
                throw SchedulerError.cyclicDependency
            }

            for resolved in wave {
                onStepStatusChanged(resolved.step.id, .running)
            }

            let waveResults = await withTaskGroup(
                of: StepResult.self,
                returning: [StepResult].self
            ) { group in
                for resolved in wave {
                    let step = resolved.step
                    let stepID = resolved.step.id
                    group.addTask {
                        await Self.executeStep(
                            step,
                            stageID: resolved.stageID,
                            workingDirectory: workDir,
                            executionControl: executionControl,
                            onOutputChunk: { chunk in
                                onStepOutput(stepID, chunk)
                            }
                        )
                    }
                }
                var results: [StepResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            var shouldStop = false
            for result in waveResults {
                allResults.append(result)

                if result.cancelledByUser {
                    finalizedStatuses[result.stepID] = .skipped
                    onStepStatusChanged(result.stepID, .skipped)
                    continue
                }

                if result.failed {
                    finalizedStatuses[result.stepID] = .failed
                    onStepStatusChanged(result.stepID, .failed)
                    let step = stepsByID[result.stepID]
                    if !(step?.continueOnFailure ?? false) {
                        shouldStop = true
                    }
                } else {
                    finalizedStatuses[result.stepID] = .completed
                    onStepStatusChanged(result.stepID, .completed)
                }
            }

            if shouldStop {
                for resolved in allSteps where finalizedStatuses[resolved.step.id] == nil {
                    finalizedStatuses[resolved.step.id] = .skipped
                    onStepStatusChanged(resolved.step.id, .skipped)
                }
                if let failed = waveResults.first(where: { $0.failed }) {
                    throw SchedulerError.stepFailed(failed)
                }
            }

            if await executionControl?.isPipelineStopRequested() == true {
                for resolved in allSteps where finalizedStatuses[resolved.step.id] == nil {
                    finalizedStatuses[resolved.step.id] = .skipped
                    onStepStatusChanged(resolved.step.id, .skipped)
                }
                throw SchedulerError.cancelled
            }
        }

        return allResults
    }

    // MARK: - Private helpers

    /// Dispatch to either a custom command runner or the legacy tool runner.
    private static func executeStep(
        _ step: PipelineStep,
        stageID: UUID,
        workingDirectory: String,
        executionControl: ExecutionControl?,
        onOutputChunk: @escaping @Sendable (String) -> Void
    ) async -> StepResult {
        let shouldTerminate: (@Sendable () async -> Bool)?
        if let executionControl {
            shouldTerminate = { [executionControl] in
                await executionControl.shouldTerminateStep(in: stageID)
            }
        } else {
            shouldTerminate = nil
        }

        do {
            if step.hasCustomCommand {
                return try await CommandRunner().execute(
                    step: step,
                    workingDirectory: workingDirectory,
                    shouldTerminate: shouldTerminate,
                    onOutputChunk: onOutputChunk
                )
            }

            let runner: any ToolRunner
            switch step.tool {
            case .codex:  runner = CodexRunner()
            case .claude: runner = ClaudeRunner()
            case .cursor: runner = CursorRunner()
            }
            return try await runner.execute(
                step: step,
                workingDirectory: workingDirectory,
                shouldTerminate: shouldTerminate,
                onOutputChunk: onOutputChunk
            )
        } catch CLIError.cancelled {
            return StepResult(
                stepID: step.id,
                exitCode: 130,
                output: "",
                error: "Stopped by user",
                cancelledByUser: true
            )
        } catch {
            return StepResult(stepID: step.id, exitCode: -1, output: "", error: error.localizedDescription)
        }
    }

    /// Kahn's algorithm – verifies the dependency graph is acyclic.
    private static func validateDAG(_ steps: [ResolvedStep]) throws {
        var inDegree: [UUID: Int] = [:]
        var adjacency: [UUID: [UUID]] = [:]

        for step in steps {
            inDegree[step.step.id, default: 0] += 0
            for dep in step.allDependencies {
                adjacency[dep, default: []].append(step.step.id)
                inDegree[step.step.id, default: 0] += 1
            }
        }

        var queue = steps.filter { inDegree[$0.step.id, default: 0] == 0 }.map(\.step.id)
        var visited = 0

        while !queue.isEmpty {
            let node = queue.removeFirst()
            visited += 1
            for neighbor in adjacency[node, default: []] {
                inDegree[neighbor]! -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        if visited != steps.count {
            throw SchedulerError.cyclicDependency
        }
    }
}
