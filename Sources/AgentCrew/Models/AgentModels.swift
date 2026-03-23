import Foundation

enum OrchestrationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case pipeline
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pipeline: L10n.text("mode.pipeline", fallback: "Pipeline")
        case .agent: L10n.text("mode.agent", fallback: "Agent")
        }
    }

    var subtitle: String {
        switch self {
        case .pipeline: L10n.text("mode.pipelineSubtitle", fallback: "Fixed steps, faster and predictable")
        case .agent: L10n.text("mode.agentSubtitle", fallback: "Round-based execution with auto replan")
        }
    }
}

enum AgentSessionStatus: String, Codable, Sendable {
    case created
    case planning
    case executing
    case evaluating
    case waitingHuman
    case completed
    case failed
    case cancelled
}

enum AgentDecision: String, Codable, Sendable {
    case `continue`
    case replan
    case askHuman
    case finish
    case abort
}

enum AgentRepairStrategy: String, Codable, Sendable {
    case originalPipeline
    case retryFailedStage
    case localPatchInsert
    case globalReplan

    var displayName: String {
        switch self {
        case .originalPipeline:
            return L10n.text("agent.strategy.originalPipeline", fallback: "Original pipeline")
        case .retryFailedStage:
            return L10n.text("agent.strategy.retryFailedStage", fallback: "Retry failed stage")
        case .localPatchInsert:
            return L10n.text("agent.strategy.localPatchInsert", fallback: "Local patch + retry")
        case .globalReplan:
            return L10n.text("agent.strategy.globalReplan", fallback: "Global replan")
        }
    }
}

enum AgentCoverageEvidenceKind: String, Codable, Sendable {
    case directReplay
    case inferredGlobalReplan
}

struct AgentCoverageItem: Identifiable, Codable, Sendable {
    let sourceStepID: UUID
    var sourceStepName: String
    var firstFailedRound: Int
    var recoveredRound: Int?
    var recoveredByStrategy: AgentRepairStrategy?
    var evidenceKind: AgentCoverageEvidenceKind?
    var evidenceNote: String?

    var id: UUID { sourceStepID }
    var isResolved: Bool { recoveredRound != nil }

    init(
        sourceStepID: UUID,
        sourceStepName: String,
        firstFailedRound: Int
    ) {
        self.sourceStepID = sourceStepID
        self.sourceStepName = sourceStepName
        self.firstFailedRound = firstFailedRound
        self.recoveredRound = nil
        self.recoveredByStrategy = nil
        self.evidenceKind = nil
        self.evidenceNote = nil
    }
}

enum RecommendationStrength: String, Sendable {
    case strong
    case weak
    case neutral
}

struct AgentRoundState: Identifiable, Codable, Sendable {
    let id: UUID
    let index: Int
    var planName: String
    var strategy: AgentRepairStrategy?
    var startedAt: Date?
    var endedAt: Date?
    var runStatus: PipelineRunStatus?
    var decision: AgentDecision?
    var summary: String
    var reasons: [String]

    init(
        id: UUID = UUID(),
        index: Int,
        planName: String,
        strategy: AgentRepairStrategy? = nil,
        summary: String = "",
        reasons: [String] = []
    ) {
        self.id = id
        self.index = index
        self.planName = planName
        self.strategy = strategy
        self.startedAt = nil
        self.endedAt = nil
        self.runStatus = nil
        self.decision = nil
        self.summary = summary
        self.reasons = reasons
    }
}

struct AgentSessionState: Identifiable, Codable, Sendable {
    let id: UUID
    let pipelineID: UUID
    var status: AgentSessionStatus
    var startedAt: Date
    var endedAt: Date?
    var currentRound: Int
    var maxRounds: Int
    var rounds: [AgentRoundState]
    var coverageItems: [AgentCoverageItem]
    var latestDecision: AgentDecision?
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        pipelineID: UUID,
        status: AgentSessionStatus = .created,
        startedAt: Date = Date(),
        currentRound: Int = 0,
        maxRounds: Int = 4,
        rounds: [AgentRoundState] = [],
        coverageItems: [AgentCoverageItem] = []
    ) {
        self.id = id
        self.pipelineID = pipelineID
        self.status = status
        self.startedAt = startedAt
        self.endedAt = nil
        self.currentRound = currentRound
        self.maxRounds = maxRounds
        self.rounds = rounds
        self.coverageItems = coverageItems
        self.latestDecision = nil
        self.failureMessage = nil
    }

    var coverageRequiredCount: Int {
        coverageItems.count
    }

    var coverageResolvedCount: Int {
        coverageItems.filter(\.isResolved).count
    }

    var unresolvedCoverageItems: [AgentCoverageItem] {
        coverageItems.filter { !$0.isResolved }
    }
}

struct ModeRecommendation: Sendable {
    let recommendedMode: OrchestrationMode
    let score: Int
    let strength: RecommendationStrength
    let hardTriggered: Bool
    let reasons: [String]
}

struct RuntimeModeSuggestion: Sendable {
    let suggestedMode: OrchestrationMode
    let reasons: [String]
}

enum ModeAnalyticsEventType: String, Codable, CaseIterable, Sendable {
    case modeRecommendationShown = "mode_recommendation_shown"
    case modeRecommendationAccepted = "mode_recommendation_accepted"
    case modeRecommendationDismissed = "mode_recommendation_dismissed"
    case modeSwitchedRuntime = "mode_switched_runtime"
    case taskOutcomeByMode = "task_outcome_by_mode"
}

struct ModeAnalyticsEvent: Identifiable, Codable, Sendable {
    let id: UUID
    let type: ModeAnalyticsEventType
    let pipelineID: UUID
    let timestamp: Date
    let payload: [String: String]

    init(
        id: UUID = UUID(),
        type: ModeAnalyticsEventType,
        pipelineID: UUID,
        timestamp: Date = Date(),
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.pipelineID = pipelineID
        self.timestamp = timestamp
        self.payload = payload
    }
}
