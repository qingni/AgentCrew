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
        sharedStateExecutionContext: SharedStateExecutionContext,
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
        let runContext = RunContextStore(steps: allSteps, workingDirectory: workDir)
        let sharedState = SharedStateStore(
            steps: allSteps,
            workingDirectory: workDir,
            pipelineName: pipeline.name,
            executionContext: sharedStateExecutionContext
        )
        var waveIndex = 0

        while finalizedStatuses.count < allSteps.count {
            if await executionControl?.isPipelineStopRequested() == true {
                for resolved in allSteps where finalizedStatuses[resolved.step.id] == nil {
                    finalizedStatuses[resolved.step.id] = .skipped
                    onStepStatusChanged(resolved.step.id, .skipped)
                    await runContext.markStatus(stepID: resolved.step.id, status: .skipped)
                }
                await runContext.writeMirrorFileIfNeeded()
                await sharedState.writeMirrorFilesIfNeeded(force: true)
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
                    await runContext.markStatus(stepID: resolved.step.id, status: .skipped)
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
                    await runContext.markStatus(stepID: resolved.step.id, status: .skipped)
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

            var runnableWave: [(resolved: ResolvedStep, step: PipelineStep)] = []
            var waveResults: [StepResult] = []
            let sharedStateSnapshot = await sharedState.freezeSnapshot(for: waveIndex)

            for resolved in wave {
                do {
                    var executableStep = resolved.step
                    let promptWithRunContext = try await runContext.renderPrompt(for: resolved.step)
                    executableStep.prompt = await sharedState.composePrompt(
                        basePrompt: promptWithRunContext,
                        for: resolved.step,
                        snapshot: sharedStateSnapshot
                    )
                    runnableWave.append((resolved: resolved, step: executableStep))
                } catch {
                    let message = "Prompt context resolution failed: \(error.localizedDescription)"
                    onStepOutput(resolved.step.id, message)
                    waveResults.append(
                        StepResult(
                            stepID: resolved.step.id,
                            exitCode: -2,
                            output: "",
                            error: message
                        )
                    )
                }
            }

            for item in runnableWave {
                onStepStatusChanged(item.resolved.step.id, .running)
                await runContext.markStatus(stepID: item.resolved.step.id, status: .running)
            }

            if !runnableWave.isEmpty {
                let executedResults = await withTaskGroup(
                    of: StepResult.self,
                    returning: [StepResult].self
                ) { group in
                    for item in runnableWave {
                        let stepID = item.resolved.step.id
                        group.addTask {
                            await Self.executeStep(
                                item.step,
                                stageID: item.resolved.stageID,
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
                waveResults.append(contentsOf: executedResults)
            }

            var shouldStop = false
            for result in waveResults {
                allResults.append(result)
                await runContext.recordResult(stepID: result.stepID, result: result)

                if result.cancelledByUser {
                    finalizedStatuses[result.stepID] = .skipped
                    onStepStatusChanged(result.stepID, .skipped)
                    await runContext.markStatus(stepID: result.stepID, status: .skipped)
                    continue
                }

                if result.failed {
                    finalizedStatuses[result.stepID] = .failed
                    onStepStatusChanged(result.stepID, .failed)
                    await runContext.markStatus(stepID: result.stepID, status: .failed)
                    let step = stepsByID[result.stepID]
                    if !(step?.continueOnFailure ?? false) {
                        shouldStop = true
                    }
                } else {
                    finalizedStatuses[result.stepID] = .completed
                    onStepStatusChanged(result.stepID, .completed)
                    await runContext.markStatus(stepID: result.stepID, status: .completed)
                }
            }

            _ = await sharedState.mergeWaveResults(waveResults, waveIndex: waveIndex)
            await runContext.writeMirrorFileIfNeeded()
            await sharedState.writeMirrorFilesIfNeeded()

            if shouldStop {
                for resolved in allSteps where finalizedStatuses[resolved.step.id] == nil {
                    finalizedStatuses[resolved.step.id] = .skipped
                    onStepStatusChanged(resolved.step.id, .skipped)
                    await runContext.markStatus(stepID: resolved.step.id, status: .skipped)
                }
                await runContext.writeMirrorFileIfNeeded()
                await sharedState.writeMirrorFilesIfNeeded(force: true)
                if let failed = waveResults.first(where: { $0.failed }) {
                    throw SchedulerError.stepFailed(failed)
                }
            }

            if await executionControl?.isPipelineStopRequested() == true {
                for resolved in allSteps where finalizedStatuses[resolved.step.id] == nil {
                    finalizedStatuses[resolved.step.id] = .skipped
                    onStepStatusChanged(resolved.step.id, .skipped)
                    await runContext.markStatus(stepID: resolved.step.id, status: .skipped)
                }
                await runContext.writeMirrorFileIfNeeded()
                await sharedState.writeMirrorFilesIfNeeded(force: true)
                throw SchedulerError.cancelled
            }

            waveIndex += 1
        }

        await runContext.writeMirrorFileIfNeeded(force: true)
        await sharedState.writeMirrorFilesIfNeeded(force: true)
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
