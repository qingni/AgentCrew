import SwiftUI
import Combine

@MainActor
final class AppViewModel: ObservableObject {

    struct ProjectGroup: Identifiable {
        let workingDirectory: String
        let displayName: String
        let pipelines: [Pipeline]

        var id: String { workingDirectory }
    }

    // MARK: - Published state

    @Published var pipelines: [Pipeline] = []
    @Published var selectedPipelineID: UUID?
    @Published var selectedStepID: UUID?

    @Published var stepStatuses: [UUID: StepStatus] = [:]
    @Published var stepOutputs: [UUID: String] = [:]
    @Published var isExecuting = false
    @Published var executingPipelineID: UUID?
    @Published var executionError: String?
    @Published var currentWave = 0
    @Published var isStopRequested = false
    @Published var stageStopRequests: Set<UUID> = []
    @Published var showFlowchart = false

    @Published var llmConfig = LLMConfig.defaultAgent
    @Published var isPlanningInProgress = false
    @Published var planningError: String?
    @Published var planningPhase: PlanningPhase?
    @Published var planningLogs: String = ""

    // MARK: - Private

    private let scheduler = DAGScheduler()
    private let planner = AIPlanner()
    private let maxRunHistoryPerPipeline = 3
    private let maxStoredStepOutputLength = 120_000
    private let maxPlanningLogLength = 80_000
    private var executionControl: ExecutionControl?

    // MARK: - Computed

    var selectedPipeline: Pipeline? {
        pipelines.first { $0.id == selectedPipelineID }
    }

    var selectedStep: PipelineStep? {
        guard let sid = selectedStepID else { return nil }
        return selectedPipeline?.allSteps.first { $0.id == sid }
    }

    var projectGroups: [ProjectGroup] {
        let grouped = Dictionary(grouping: pipelines) { pipeline in
            pipeline.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return grouped
            .map { workingDirectory, pipelinesInProject in
                let displayName = Pipeline.suggestedName(forWorkingDirectory: workingDirectory)
                    ?? "Unknown Project"
                return ProjectGroup(
                    workingDirectory: workingDirectory,
                    displayName: displayName,
                    pipelines: pipelinesInProject.sorted { lhs, rhs in
                        lhs.createdAt < rhs.createdAt
                    }
                )
            }
            .sorted { lhs, rhs in
                let nameCompare = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if nameCompare != .orderedSame {
                    return nameCompare == .orderedAscending
                }
                return lhs.workingDirectory.localizedCaseInsensitiveCompare(rhs.workingDirectory) == .orderedAscending
            }
    }

    var knownProjectDirectories: [String] {
        projectGroups
            .map(\.workingDirectory)
            .filter { !$0.isEmpty }
    }

    // MARK: - Init

    init() { loadPipelines() }

    // MARK: - Pipeline CRUD

    func createPipeline(name: String, workingDirectory: String) {
        guard !name.isEmpty, !workingDirectory.isEmpty else { return }
        let p = Pipeline(name: name, workingDirectory: workingDirectory)
        pipelines.append(p)
        selectedPipelineID = p.id
        savePipelines()
    }

    func deletePipeline(_ id: UUID) {
        guard !isPipelineExecuting(id) else { return }
        pipelines.removeAll { $0.id == id }
        if selectedPipelineID == id { selectedPipelineID = pipelines.first?.id }
        savePipelines()
    }

    func addStage(to pipelineID: UUID, name: String, mode: ExecutionMode) {
        guard let i = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        guard isPipelineEditable(at: i) else { return }
        pipelines[i].stages.append(PipelineStage(name: name, executionMode: mode))
        savePipelines()
    }

    func deleteStage(_ stageID: UUID, from pipelineID: UUID) {
        guard let i = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        guard isPipelineEditable(at: i) else { return }
        pipelines[i].stages.removeAll { $0.id == stageID }
        savePipelines()
    }

    func addStep(to stageID: UUID, in pipelineID: UUID, step: PipelineStep) {
        guard let pi = pipelines.firstIndex(where: { $0.id == pipelineID }),
              let si = pipelines[pi].stages.firstIndex(where: { $0.id == stageID })
        else { return }
        guard isPipelineEditable(at: pi) else { return }
        pipelines[pi].stages[si].steps.append(step)
        savePipelines()
    }

    func updateStep(_ step: PipelineStep, in pipelineID: UUID) {
        guard let pi = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        guard isPipelineEditable(at: pi) else { return }
        for si in pipelines[pi].stages.indices {
            if let idx = pipelines[pi].stages[si].steps.firstIndex(where: { $0.id == step.id }) {
                pipelines[pi].stages[si].steps[idx] = step
                savePipelines()
                return
            }
        }
    }

    func deleteStep(_ stepID: UUID, from pipelineID: UUID) {
        guard let pi = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        guard isPipelineEditable(at: pi) else { return }
        for si in pipelines[pi].stages.indices {
            pipelines[pi].stages[si].steps.removeAll { $0.id == stepID }
        }
        if selectedStepID == stepID { selectedStepID = nil }
        savePipelines()
    }

    func updateStage(_ stageID: UUID, in pipelineID: UUID, name: String? = nil, mode: ExecutionMode? = nil) {
        guard let pi = pipelines.firstIndex(where: { $0.id == pipelineID }),
              let si = pipelines[pi].stages.firstIndex(where: { $0.id == stageID })
        else { return }
        guard isPipelineEditable(at: pi) else { return }
        if let n = name { pipelines[pi].stages[si].name = n }
        if let m = mode { pipelines[pi].stages[si].executionMode = m }
        savePipelines()
    }

    func updatePipeline(_ pipelineID: UUID, name: String? = nil, workingDirectory: String? = nil) {
        guard let i = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        guard isPipelineEditable(at: i) else { return }
        if let n = name { pipelines[i].name = n }
        if let d = workingDirectory { pipelines[i].workingDirectory = d }
        savePipelines()
    }

    /// Creates a pre-populated demo pipeline so users can see the structure.
    func createDemoPipeline(workingDirectory: String) {
        guard !workingDirectory.isEmpty else { return }
        let template = makeDemoTemplate()

        let pipeline = Pipeline(
            name: "Demo: Code + Review",
            stages: template.stages,
            workingDirectory: workingDirectory
        )
        pipelines.append(pipeline)
        selectedPipelineID = pipeline.id
        selectedStepID = template.initialStepID
        savePipelines()
    }

    func loadDemoTemplate(into pipelineID: UUID) {
        guard let index = pipelines.firstIndex(where: { $0.id == pipelineID }),
              isPipelineEditable(at: index),
              pipelines[index].stages.isEmpty
        else { return }

        let template = makeDemoTemplate()
        pipelines[index].stages = template.stages
        selectedPipelineID = pipelines[index].id
        selectedStepID = template.initialStepID
        savePipelines()
    }

    // MARK: - Execution

    func executePipeline(_ pipeline: Pipeline) async {
        guard !isExecuting else { return }
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipeline.id }) else { return }
        let pipelineID = pipelines[pipelineIndex].id
        let pipelineSnapshot = pipelines[pipelineIndex]

        isExecuting = true
        executingPipelineID = pipelineID
        executionError = nil
        stepStatuses = [:]
        stepOutputs = [:]
        currentWave = 0
        isStopRequested = false
        stageStopRequests = []

        let control = ExecutionControl()
        executionControl = control
        defer {
            executionControl = nil
            isExecuting = false
            executingPipelineID = nil
            isStopRequested = false
            stageStopRequests = []
        }

        for step in pipelineSnapshot.allSteps {
            stepStatuses[step.id] = .pending
        }

        let runID = startRunRecord(for: pipelineID)
        let ref = WeakVM(vm: self)

        do {
            _ = try await scheduler.executePipeline(
                pipelineSnapshot,
                executionControl: control,
                onStepStatusChanged: { id, status in
                    Task { @MainActor in
                        ref.vm?.stepStatuses[id] = status
                        if let runID {
                            ref.vm?.recordStepStatus(
                                pipelineID: pipelineID,
                                runID: runID,
                                stepID: id,
                                status: status,
                                timestamp: Date()
                            )
                        }
                    }
                },
                onStepOutput: { id, output in
                    Task { @MainActor in
                        ref.vm?.stepOutputs[id, default: ""].append(output)
                        if let runID {
                            ref.vm?.recordStepOutput(
                                pipelineID: pipelineID,
                                runID: runID,
                                stepID: id,
                                outputChunk: output
                            )
                        }
                    }
                }
            )
            if let runID {
                finalizeRunRecord(
                    pipelineID: pipelineID,
                    runID: runID,
                    status: .completed,
                    errorMessage: nil,
                    finishedAt: Date()
                )
            }
        } catch {
            let runStatus: PipelineRunStatus
            if let schedulerError = error as? SchedulerError {
                switch schedulerError {
                case .cancelled:
                    executionError = "Pipeline stopped by user."
                    runStatus = .cancelled
                default:
                    executionError = error.localizedDescription
                    runStatus = .failed
                }
            } else {
                executionError = error.localizedDescription
                runStatus = .failed
            }
            if let runID {
                finalizeRunRecord(
                    pipelineID: pipelineID,
                    runID: runID,
                    status: runStatus,
                    errorMessage: executionError,
                    finishedAt: Date()
                )
            }
        }

        if let index = pipelines.firstIndex(where: { $0.id == pipelineID }),
           pipelines[index].lockedAfterFirstRunAt == nil {
            pipelines[index].lockedAfterFirstRunAt = Date()
        }

        savePipelines()
    }

    func retryStage(_ stageID: UUID, in pipelineID: UUID) async {
        guard !isExecuting else { return }
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        guard let stageIndex = pipelines[pipelineIndex].stages.firstIndex(where: { $0.id == stageID }) else { return }

        var retryStage = pipelines[pipelineIndex].stages[stageIndex]
        guard !retryStage.steps.isEmpty else { return }

        // Keep only in-stage dependencies so retry can run independently.
        let stageStepIDs = Set(retryStage.steps.map(\.id))
        for stepIndex in retryStage.steps.indices {
            retryStage.steps[stepIndex].dependsOnStepIDs = retryStage.steps[stepIndex].dependsOnStepIDs.filter {
                stageStepIDs.contains($0)
            }
        }

        var retrySnapshot = pipelines[pipelineIndex]
        retrySnapshot.stages = [retryStage]

        isExecuting = true
        executingPipelineID = pipelineID
        executionError = nil
        stepStatuses = latestKnownStepStatuses(for: pipelines[pipelineIndex])
        for step in retryStage.steps {
            stepStatuses[step.id] = .pending
        }
        stepOutputs = [:]
        currentWave = 0
        isStopRequested = false
        stageStopRequests = []

        let control = ExecutionControl()
        executionControl = control
        defer {
            executionControl = nil
            isExecuting = false
            executingPipelineID = nil
            isStopRequested = false
            stageStopRequests = []
        }

        let runID = startRunRecord(for: pipelineID, stageIDs: Set([stageID]))
        let ref = WeakVM(vm: self)

        do {
            _ = try await scheduler.executePipeline(
                retrySnapshot,
                executionControl: control,
                onStepStatusChanged: { id, status in
                    Task { @MainActor in
                        ref.vm?.stepStatuses[id] = status
                        if let runID {
                            ref.vm?.recordStepStatus(
                                pipelineID: pipelineID,
                                runID: runID,
                                stepID: id,
                                status: status,
                                timestamp: Date()
                            )
                        }
                    }
                },
                onStepOutput: { id, output in
                    Task { @MainActor in
                        ref.vm?.stepOutputs[id, default: ""].append(output)
                        if let runID {
                            ref.vm?.recordStepOutput(
                                pipelineID: pipelineID,
                                runID: runID,
                                stepID: id,
                                outputChunk: output
                            )
                        }
                    }
                }
            )
            if let runID {
                finalizeRunRecord(
                    pipelineID: pipelineID,
                    runID: runID,
                    status: .completed,
                    errorMessage: nil,
                    finishedAt: Date()
                )
            }
        } catch {
            let runStatus: PipelineRunStatus
            if let schedulerError = error as? SchedulerError {
                switch schedulerError {
                case .cancelled:
                    executionError = "Stage retry stopped by user."
                    runStatus = .cancelled
                default:
                    executionError = error.localizedDescription
                    runStatus = .failed
                }
            } else {
                executionError = error.localizedDescription
                runStatus = .failed
            }
            if let runID {
                finalizeRunRecord(
                    pipelineID: pipelineID,
                    runID: runID,
                    status: runStatus,
                    errorMessage: executionError,
                    finishedAt: Date()
                )
            }
        }

        if pipelines[pipelineIndex].lockedAfterFirstRunAt == nil {
            pipelines[pipelineIndex].lockedAfterFirstRunAt = Date()
        }

        savePipelines()
    }

    func stopPipeline() {
        guard isExecuting else { return }
        isStopRequested = true
        Task {
            await executionControl?.requestPipelineStop()
        }
    }

    func stopStage(_ stageID: UUID, in pipelineID: UUID) {
        guard isExecuting else { return }
        guard executingPipelineID == pipelineID else { return }
        guard let pipeline = pipelines.first(where: { $0.id == pipelineID }),
              pipeline.stages.contains(where: { $0.id == stageID })
        else { return }

        stageStopRequests.insert(stageID)
        Task {
            await executionControl?.requestStageStop(stageID)
        }
    }

    func isStageStopRequested(_ stageID: UUID) -> Bool {
        stageStopRequests.contains(stageID)
    }

    func isPipelineExecuting(_ pipelineID: UUID) -> Bool {
        isExecuting && executingPipelineID == pipelineID
    }

    func latestStageStatus(pipelineID: UUID, stageID: UUID) -> StepStatus? {
        guard let pipeline = pipelines.first(where: { $0.id == pipelineID }) else { return nil }
        let sortedHistory = pipeline.runHistory.sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }

        for run in sortedHistory {
            if let stageRun = run.stageRuns.first(where: { $0.stageID == stageID }) {
                return stageRun.status
            }
        }
        return nil
    }

    func latestStepStatus(pipelineID: UUID, stepID: UUID) -> StepStatus? {
        guard let pipeline = pipelines.first(where: { $0.id == pipelineID }) else { return nil }
        let sortedHistory = pipeline.runHistory.sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }

        for run in sortedHistory {
            for stageRun in run.stageRuns {
                if let stepRun = stageRun.stepRuns.first(where: { $0.stepID == stepID }) {
                    return stepRun.status
                }
            }
        }
        return nil
    }

    // MARK: - AI Planning

    func generatePipeline(from prompt: String, workingDirectory: String) async {
        guard !workingDirectory.isEmpty else {
            planningError = "Select a project before generating a pipeline."
            planningPhase = nil
            return
        }

        isPlanningInProgress = true
        planningError = nil
        planningPhase = .preparingContext
        planningLogs = ""
        defer { isPlanningInProgress = false }

        do {
            let req = PlanRequest(userPrompt: prompt, workingDirectory: workingDirectory)
            let ref = WeakVM(vm: self)
            let pipeline = try await planner.generatePipeline(
                request: req,
                config: llmConfig,
                onPhaseUpdate: { phase in
                    Task { @MainActor in
                        ref.vm?.planningPhase = phase
                    }
                },
                onLog: { chunk in
                    Task { @MainActor in
                        ref.vm?.appendPlanningLog(chunk)
                    }
                }
            )
            planningPhase = .creatingPipeline
            pipelines.append(pipeline)
            selectedPipelineID = pipeline.id
            savePipelines()
            planningPhase = nil
        } catch {
            planningError = error.localizedDescription
        }
    }

    func resetPlanningState() {
        guard !isPlanningInProgress else { return }
        planningError = nil
        planningPhase = nil
        planningLogs = ""
    }

    // MARK: - Persistence

    func savePipelines() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(pipelines) else { return }
        try? data.write(to: Self.pipelinesFileURL)
    }

    func loadPipelines() {
        guard let data = try? Data(contentsOf: Self.pipelinesFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([Pipeline].self, from: data) {
            var normalized = loaded
            var didTrimHistory = false

            for index in normalized.indices {
                if normalized[index].runHistory.count > maxRunHistoryPerPipeline {
                    normalized[index].runHistory = Array(
                        normalized[index].runHistory.suffix(maxRunHistoryPerPipeline)
                    )
                    didTrimHistory = true
                }
            }

            pipelines = normalized
            if didTrimHistory {
                savePipelines()
            }
        }
    }

    private static var pipelinesFileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentCrew", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pipelines.json")
    }

    // MARK: - Lock / Run history helpers

    func isPipelineLocked(_ pipelineID: UUID) -> Bool {
        guard let index = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return false }
        return pipelines[index].isLockedAfterRun
    }

    private func isPipelineEditable(at pipelineIndex: Int) -> Bool {
        !pipelines[pipelineIndex].isLockedAfterRun
            && !isPipelineExecuting(pipelines[pipelineIndex].id)
    }

    private func startRunRecord(
        for pipelineID: UUID,
        stageIDs: Set<UUID>? = nil
    ) -> UUID? {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return nil }
        var runPipeline = pipelines[pipelineIndex]
        if let stageIDs {
            runPipeline.stages = runPipeline.stages.filter { stageIDs.contains($0.id) }
        }

        var run = PipelineRunRecord(pipeline: runPipeline, startedAt: Date())
        run.stageRuns = run.stageRuns.map { stageRun in
            var mutableStage = stageRun
            mutableStage.startedAt = nil
            mutableStage.endedAt = nil
            return mutableStage
        }
        pipelines[pipelineIndex].runHistory.append(run)
        if pipelines[pipelineIndex].runHistory.count > maxRunHistoryPerPipeline {
            pipelines[pipelineIndex].runHistory.removeFirst(
                pipelines[pipelineIndex].runHistory.count - maxRunHistoryPerPipeline
            )
        }
        return run.id
    }

    private func latestKnownStepStatuses(for pipeline: Pipeline) -> [UUID: StepStatus] {
        let allStepIDs = Set(pipeline.allSteps.map(\.id))
        guard !allStepIDs.isEmpty else { return [:] }

        var statuses: [UUID: StepStatus] = [:]
        let sortedHistory = pipeline.runHistory.sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }

        for run in sortedHistory {
            for stepRun in run.stageRuns.flatMap(\.stepRuns) where allStepIDs.contains(stepRun.stepID) {
                if statuses[stepRun.stepID] == nil {
                    statuses[stepRun.stepID] = stepRun.status
                }
            }
            if statuses.count == allStepIDs.count {
                break
            }
        }

        return statuses
    }

    private func recordStepStatus(
        pipelineID: UUID,
        runID: UUID,
        stepID: UUID,
        status: StepStatus,
        timestamp: Date
    ) {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }),
              let runIndex = pipelines[pipelineIndex].runHistory.firstIndex(where: { $0.id == runID })
        else { return }

        var run = pipelines[pipelineIndex].runHistory[runIndex]

        for stageIndex in run.stageRuns.indices {
            guard let stepIndex = run.stageRuns[stageIndex].stepRuns.firstIndex(where: { $0.stepID == stepID }) else {
                continue
            }

            var stage = run.stageRuns[stageIndex]
            var stepRun = stage.stepRuns[stepIndex]
            stepRun.status = status

            if status == .running, stepRun.startedAt == nil {
                stepRun.startedAt = timestamp
            }
            if (status == .completed || status == .failed || status == .skipped), stepRun.endedAt == nil {
                stepRun.endedAt = timestamp
            }

            stage.stepRuns[stepIndex] = stepRun

            if stage.startedAt == nil, (status == .running || status == .completed || status == .failed) {
                stage.startedAt = timestamp
            }

            if stage.finishedSteps == stage.totalSteps, stage.endedAt == nil {
                stage.endedAt = timestamp
            }

            run.stageRuns[stageIndex] = stage
            break
        }

        pipelines[pipelineIndex].runHistory[runIndex] = run
    }

    private func recordStepOutput(
        pipelineID: UUID,
        runID: UUID,
        stepID: UUID,
        outputChunk: String
    ) {
        guard !outputChunk.isEmpty else { return }
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }),
              let runIndex = pipelines[pipelineIndex].runHistory.firstIndex(where: { $0.id == runID })
        else { return }

        var run = pipelines[pipelineIndex].runHistory[runIndex]

        for stageIndex in run.stageRuns.indices {
            guard let stepIndex = run.stageRuns[stageIndex].stepRuns.firstIndex(where: { $0.stepID == stepID }) else {
                continue
            }

            var stage = run.stageRuns[stageIndex]
            var stepRun = stage.stepRuns[stepIndex]
            let existingOutput = stepRun.output ?? ""
            let mergedOutput = existingOutput + outputChunk
            stepRun.output = trimmedStoredOutput(mergedOutput)

            stage.stepRuns[stepIndex] = stepRun
            run.stageRuns[stageIndex] = stage
            break
        }

        pipelines[pipelineIndex].runHistory[runIndex] = run
    }

    private func trimmedStoredOutput(_ output: String) -> String {
        guard output.count > maxStoredStepOutputLength else { return output }
        let suffixCount = maxStoredStepOutputLength
        let tail = String(output.suffix(suffixCount))
        return """
        ...output truncated...
        \(tail)
        """
    }

    private func appendPlanningLog(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        planningLogs.append(chunk)
        if planningLogs.count > maxPlanningLogLength {
            let tail = String(planningLogs.suffix(maxPlanningLogLength))
            planningLogs = """
            ...log truncated...
            \(tail)
            """
        }
    }

    private func finalizeRunRecord(
        pipelineID: UUID,
        runID: UUID,
        status: PipelineRunStatus,
        errorMessage: String?,
        finishedAt: Date
    ) {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }),
              let runIndex = pipelines[pipelineIndex].runHistory.firstIndex(where: { $0.id == runID })
        else { return }

        var run = pipelines[pipelineIndex].runHistory[runIndex]
        run.status = status
        run.errorMessage = errorMessage
        run.endedAt = finishedAt

        for stageIndex in run.stageRuns.indices {
            var stage = run.stageRuns[stageIndex]
            if stage.startedAt != nil, stage.endedAt == nil, stage.finishedSteps == stage.totalSteps {
                stage.endedAt = finishedAt
            }
            run.stageRuns[stageIndex] = stage
        }

        pipelines[pipelineIndex].runHistory[runIndex] = run
    }

    private func makeDemoTemplate() -> (stages: [PipelineStage], initialStepID: UUID) {
        let codingA = PipelineStep(
            name: "Implement feature A",
            prompt: "Implement the user login form with email and password fields.",
            tool: .codex
        )
        let codingB = PipelineStep(
            name: "Implement feature B",
            prompt: "Implement the user registration form with validation.",
            tool: .codex
        )
        let review = PipelineStep(
            name: "Code review",
            prompt: "Review all changed files for bugs, security issues, and code style.",
            tool: .cursor
        )
        let verify = PipelineStep(
            name: "Verify & fix",
            prompt: "Run the project, fix any compilation errors or test failures.",
            tool: .codex
        )

        let stage1 = PipelineStage(name: "Coding", steps: [codingA, codingB], executionMode: .parallel)
        let stage2 = PipelineStage(name: "Review", steps: [review, verify], executionMode: .sequential)
        return ([stage1, stage2], codingA.id)
    }
}

/// Sendable wrapper for weak ViewModel reference, used to cross isolation boundaries.
private struct WeakVM: @unchecked Sendable {
    weak var vm: AppViewModel?
}
