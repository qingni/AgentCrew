import Foundation

// MARK: - Enums

enum StepStatus: String, Codable, Sendable {
    case pending, running, completed, failed, skipped
}

enum ExecutionMode: String, Codable, CaseIterable, Sendable {
    case parallel, sequential
}

enum PipelineRunStatus: String, Codable, Sendable {
    case running, completed, failed, cancelled
}

// MARK: - PipelineStep

struct PipelineStep: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var command: String?
    var prompt: String
    var tool: ToolType
    var model: String?
    var dependsOnStepIDs: [UUID]
    var continueOnFailure: Bool
    var status: StepStatus
    var output: String?
    var error: String?

    init(
        id: UUID = UUID(),
        name: String,
        command: String? = nil,
        prompt: String,
        tool: ToolType = .codex,
        model: String? = nil,
        dependsOnStepIDs: [UUID] = [],
        continueOnFailure: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.prompt = prompt
        self.tool = tool
        self.model = model
        self.dependsOnStepIDs = dependsOnStepIDs
        self.continueOnFailure = continueOnFailure
        self.status = .pending
    }

    static func == (lhs: PipelineStep, rhs: PipelineStep) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var hasCustomCommand: Bool {
        !(command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func effectiveCommand(profile: CLIProfile) -> String {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return normalizedCommand(trimmed, profile: profile)
        }
        return tool.defaultCommandTemplate(model: model, profile: profile)
    }

    var displayTool: ToolType? {
        if hasCustomCommand, let cmd = command {
            return ToolType.detected(fromCommandLine: cmd)
        }
        return tool
    }

    private func normalizedCommand(_ commandLine: String, profile: CLIProfile) -> String {
        let sanitized = commandLine
            .replacingOccurrences(of: "\"{{prompt}}\"", with: "{{prompt}}")
            .replacingOccurrences(of: "'{{prompt}}'", with: "{{prompt}}")

        if isLegacyCursorCommand(sanitized) {
            return ToolType.cursor.defaultCommandTemplate(model: extractedModel(from: sanitized) ?? model, profile: profile)
        }

        if isLegacyCodexCommand(sanitized) {
            return ToolType.codex.defaultCommandTemplate(model: extractedModel(from: sanitized) ?? model, profile: profile)
        }

        return sanitized
    }

    private func isLegacyCursorCommand(_ commandLine: String) -> Bool {
        let lower = commandLine.lowercased()
        return lower.contains("cursor --trust")
            || lower.contains("agent --trust")
            || lower.contains("cursor-agent -p -f")
            || lower.contains("|| agent -p -f")
            || lower.contains("agent -p -f")
    }

    private func isLegacyCodexCommand(_ commandLine: String) -> Bool {
        let lower = commandLine.lowercased()
        return tool == .codex
            && (
                lower.hasPrefix("codex exec ")
                || lower.contains("codex exec --cd ")
                || lower.contains("codex-internal exec --cd ")
            )
    }

    private func extractedModel(from commandLine: String) -> String? {
        let parts = commandLine.split(whereSeparator: \.isWhitespace)
        guard let modelIndex = parts.firstIndex(of: "--model") else { return nil }
        let valueIndex = parts.index(after: modelIndex)
        guard valueIndex < parts.endIndex else { return nil }
        return String(parts[valueIndex])
    }
}

// MARK: - PipelineStage

struct PipelineStage: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var steps: [PipelineStep]
    var executionMode: ExecutionMode

    init(
        id: UUID = UUID(),
        name: String,
        steps: [PipelineStep] = [],
        executionMode: ExecutionMode = .parallel
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.executionMode = executionMode
    }
}

// MARK: - Run History

struct StepRunRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let stepID: UUID
    var stepName: String
    var status: StepStatus
    var startedAt: Date?
    var endedAt: Date?
    var output: String?

    init(step: PipelineStep) {
        self.id = UUID()
        self.stepID = step.id
        self.stepName = step.name
        self.status = .pending
        self.output = nil
    }
}

struct StageRunRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let stageID: UUID
    var stageName: String
    var stepRuns: [StepRunRecord]
    var startedAt: Date?
    var endedAt: Date?

    init(stage: PipelineStage) {
        self.id = UUID()
        self.stageID = stage.id
        self.stageName = stage.name
        self.stepRuns = stage.steps.map(StepRunRecord.init(step:))
    }

    var totalSteps: Int { stepRuns.count }

    var completedSteps: Int {
        stepRuns.filter { $0.status == .completed }.count
    }

    var failedSteps: Int {
        stepRuns.filter { $0.status == .failed }.count
    }

    var skippedSteps: Int {
        stepRuns.filter { $0.status == .skipped }.count
    }

    var runningSteps: Int {
        stepRuns.filter { $0.status == .running }.count
    }

    var finishedSteps: Int {
        completedSteps + failedSteps + skippedSteps
    }

    var progress: Double {
        guard totalSteps > 0 else { return 1.0 }
        return Double(finishedSteps) / Double(totalSteps)
    }

    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    var status: StepStatus {
        if totalSteps == 0 { return .completed }
        if failedSteps > 0 { return .failed }
        if skippedSteps == totalSteps { return .skipped }
        if finishedSteps == totalSteps { return .completed }
        if runningSteps > 0 { return .running }
        return .pending
    }
}

struct PipelineRunRecord: Identifiable, Codable, Sendable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var status: PipelineRunStatus
    var stageRuns: [StageRunRecord]
    var errorMessage: String?
    var orchestrationMode: OrchestrationMode?
    var agentRoundIndex: Int?
    var agentStrategy: AgentRepairStrategy?
    var coverageSnapshot: [AgentCoverageItem]?

    init(pipeline: Pipeline, startedAt: Date = Date()) {
        self.id = UUID()
        self.startedAt = startedAt
        self.endedAt = nil
        self.status = .running
        self.stageRuns = pipeline.stages.map(StageRunRecord.init(stage:))
        self.errorMessage = nil
        self.orchestrationMode = nil
        self.agentRoundIndex = nil
        self.agentStrategy = nil
        self.coverageSnapshot = nil
    }

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    var completedStages: Int {
        stageRuns.filter { $0.finishedSteps == $0.totalSteps }.count
    }
}

// MARK: - Pipeline

struct Pipeline: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var stages: [PipelineStage]
    var workingDirectory: String
    var isAIGenerated: Bool
    var createdAt: Date
    var runHistory: [PipelineRunRecord]
    var preferredRunMode: OrchestrationMode
    // Legacy persisted field retained so older saved pipeline data still decodes.
    var lockedAfterFirstRunAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        stages: [PipelineStage] = [],
        workingDirectory: String = "",
        isAIGenerated: Bool = false,
        runHistory: [PipelineRunRecord] = [],
        preferredRunMode: OrchestrationMode = .pipeline,
        lockedAfterFirstRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.stages = stages
        self.workingDirectory = workingDirectory
        self.isAIGenerated = isAIGenerated
        self.createdAt = Date()
        self.runHistory = runHistory
        self.preferredRunMode = preferredRunMode
        self.lockedAfterFirstRunAt = lockedAfterFirstRunAt
    }

    var allSteps: [PipelineStep] {
        stages.flatMap { $0.steps }
    }

    static func suggestedName(forWorkingDirectory workingDirectory: String) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let projectName = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !projectName.isEmpty else { return nil }
        return projectName
    }

    var projectDisplayName: String {
        Pipeline.suggestedName(forWorkingDirectory: workingDirectory) ?? "No project selected"
    }

    /// Flatten all steps with resolved dependencies, injecting implicit
    /// sequential dependencies within stages that use `.sequential` mode.
    func allStepsWithResolvedDependencies() -> [ResolvedStep] {
        var resolved: [ResolvedStep] = []
        for stage in stages {
            for (index, step) in stage.steps.enumerated() {
                var deps = Set(step.dependsOnStepIDs)
                if stage.executionMode == .sequential, index > 0 {
                    deps.insert(stage.steps[index - 1].id)
                }
                resolved.append(ResolvedStep(step: step, allDependencies: deps, stageID: stage.id))
            }
        }
        return resolved
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case stages
        case workingDirectory
        case isAIGenerated
        case createdAt
        case runHistory
        case preferredRunMode
        case lockedAfterFirstRunAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.stages = try container.decodeIfPresent([PipelineStage].self, forKey: .stages) ?? []
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        self.isAIGenerated = try container.decodeIfPresent(Bool.self, forKey: .isAIGenerated) ?? false
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.runHistory = try container.decodeIfPresent([PipelineRunRecord].self, forKey: .runHistory) ?? []
        self.preferredRunMode = try container.decodeIfPresent(OrchestrationMode.self, forKey: .preferredRunMode) ?? .pipeline
        self.lockedAfterFirstRunAt = try container.decodeIfPresent(Date.self, forKey: .lockedAfterFirstRunAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(stages, forKey: .stages)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(isAIGenerated, forKey: .isAIGenerated)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(runHistory, forKey: .runHistory)
        try container.encode(preferredRunMode, forKey: .preferredRunMode)
        try container.encode(lockedAfterFirstRunAt, forKey: .lockedAfterFirstRunAt)
    }
}

// MARK: - ResolvedStep

struct ResolvedStep: Sendable {
    let step: PipelineStep
    let allDependencies: Set<UUID>
    let stageID: UUID
}
