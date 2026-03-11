import Foundation

enum PlanningPhase: Int, CaseIterable, Sendable {
    case preparingContext
    case invokingAgentCLI
    case generatingStructure
    case parsingResult
    case creatingPipeline

    var title: String {
        switch self {
        case .preparingContext: "Prepare task context"
        case .invokingAgentCLI: "Invoke Agent CLI"
        case .generatingStructure: "Generate pipeline structure"
        case .parsingResult: "Parse structured JSON"
        case .creatingPipeline: "Create pipeline in app"
        }
    }
}

// MARK: - Plan Request / Response

struct PlanRequest: Codable, Sendable {
    let userPrompt: String
    let workingDirectory: String
    let availableTools: [ToolType]

    init(
        userPrompt: String,
        workingDirectory: String,
        availableTools: [ToolType] = ToolType.allCases
    ) {
        self.userPrompt = userPrompt
        self.workingDirectory = workingDirectory
        self.availableTools = availableTools
    }
}

struct PlanResponse: Codable, Sendable {
    let pipelineName: String
    let stages: [PlannedStage]

    func toPipeline(workingDirectory: String) -> Pipeline {
        var stepNameToID: [String: UUID] = [:]
        var pipelineStages: [PipelineStage] = []

        for plannedStage in stages {
            let mode = ExecutionMode(rawValue: plannedStage.executionMode) ?? .parallel
            var steps: [PipelineStep] = []

            for plannedStep in plannedStage.steps {
                let resolvedTool = plannedStep.resolvedTool(stageName: plannedStage.name)
                let stepID = UUID()
                stepNameToID[plannedStep.name] = stepID

                let deps = (plannedStep.dependsOn ?? []).compactMap { stepNameToID[$0] }
                let step = PipelineStep(
                    id: stepID,
                    name: plannedStep.name,
                    command: resolvedTool.defaultCommandTemplate(model: plannedStep.model),
                    prompt: plannedStep.prompt,
                    tool: resolvedTool,
                    model: plannedStep.model,
                    dependsOnStepIDs: deps,
                    continueOnFailure: plannedStep.continueOnFailure ?? false
                )
                steps.append(step)
            }

            pipelineStages.append(PipelineStage(name: plannedStage.name, steps: steps, executionMode: mode))
        }

        return Pipeline(name: pipelineName, stages: pipelineStages, workingDirectory: workingDirectory)
    }
}

struct PlannedStage: Codable, Sendable {
    let name: String
    let executionMode: String
    let steps: [PlannedStep]
}

struct PlannedStep: Codable, Sendable {
    let name: String
    let prompt: String
    let recommendedTool: String
    let model: String?
    let dependsOn: [String]?
    let continueOnFailure: Bool?

    func resolvedTool(stageName: String) -> ToolType {
        let normalizedName = name.lowercased()
        let normalizedStageName = stageName.lowercased()

        if normalizedName.contains("verify") || normalizedName.contains("fix") {
            return .codex
        }

        if normalizedName.contains("review") || normalizedStageName.contains("review") {
            return .cursor
        }

        if normalizedName.contains("implement")
            || normalizedName.contains("feature")
            || normalizedStageName.contains("coding")
            || normalizedStageName.contains("implement")
        {
            return .codex
        }

        return ToolType.fromKeyword(recommendedTool)
    }
}

// MARK: - Planner Configuration

struct LLMConfig: Codable, Sendable {
    var model: String

    static let defaultAgent = LLMConfig(model: "opus-4.6")

    init(model: String) {
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case model
        // Legacy keys kept for backward decode compatibility.
        case apiKey
        case baseURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultAgent.model
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
    }
}
