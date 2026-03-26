import Foundation

enum SharedStateKind: String, Codable, CaseIterable, Sendable {
    case decision
    case fact
    case artifactRef
    case issue
    case resource
}

enum SharedStateStatus: String, Codable, Sendable {
    case active
    case superseded
    case conflicted
    case resolved
    case expired
}

enum SharedStateMutability: String, Codable, Sendable {
    case immutable
    case supersedable
    case appendOnly
    case ephemeral
}

enum SharedStateLifetime: String, Codable, Sendable {
    case session
    case round
    case wave
    case untilResolved
}

enum SharedStateVisibilityKind: String, Codable, Sendable {
    case pipeline
    case dependencyChain
    case stage
    case steps
}

struct SharedStateVisibility: Codable, Sendable, Hashable {
    var kind: SharedStateVisibilityKind
    var stageID: UUID?
    var stepIDs: [UUID]

    init(
        kind: SharedStateVisibilityKind,
        stageID: UUID? = nil,
        stepIDs: [UUID] = []
    ) {
        self.kind = kind
        self.stageID = stageID
        self.stepIDs = stepIDs
    }

    static let pipeline = SharedStateVisibility(kind: .pipeline)
    static let dependencyChain = SharedStateVisibility(kind: .dependencyChain)

    static func stage(_ stageID: UUID) -> SharedStateVisibility {
        SharedStateVisibility(kind: .stage, stageID: stageID)
    }

    static func steps(_ stepIDs: [UUID]) -> SharedStateVisibility {
        SharedStateVisibility(kind: .steps, stepIDs: stepIDs)
    }
}

struct SharedStateSource: Codable, Sendable, Hashable {
    var stepID: UUID?
    var stepName: String?
    var stageID: UUID?
    var roundIndex: Int
    var waveIndex: Int?
}

enum SharedDecisionStrength: String, Codable, Sendable {
    case hard
    case soft
}

struct SharedDecisionState: Codable, Sendable, Hashable {
    var category: String
    var strength: SharedDecisionStrength
    var decision: String
    var rationale: String
    var constraints: [String]
    var artifacts: [String]
}

struct SharedFactState: Codable, Sendable, Hashable {
    var statement: String
    var evidence: [String]
    var confidence: Double?
}

enum SharedArtifactRole: String, Codable, Sendable {
    case generated
    case sourceFile
    case testFile
    case config
    case report
    case document
    case tempOutput
}

struct SharedArtifactRefState: Codable, Sendable, Hashable {
    var path: String
    var role: SharedArtifactRole
    var summary: String
}

enum SharedIssueSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
    case blocker
}

struct SharedIssueState: Codable, Sendable, Hashable {
    var severity: SharedIssueSeverity
    var summary: String
    var details: [String]
    var relatedArtifacts: [String]
}

enum SharedResourceKind: String, Codable, Sendable {
    case localPort
    case tempDirectory
    case sessionReference
    case fileLock
    case other
}

struct SharedResourceState: Codable, Sendable, Hashable {
    var kind: SharedResourceKind
    var value: String
    var expiresAt: Date?
}

struct SharedStateEntry: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var kind: SharedStateKind
    var scope: String
    var title: String
    var status: SharedStateStatus
    var visibility: SharedStateVisibility
    var mutability: SharedStateMutability
    var lifetime: SharedStateLifetime
    var source: SharedStateSource
    var supersedes: [UUID]
    var createdAt: Date
    var updatedAt: Date

    var decision: SharedDecisionState?
    var fact: SharedFactState?
    var artifactRef: SharedArtifactRefState?
    var issue: SharedIssueState?
    var resource: SharedResourceState?
}

struct ProposedSharedStateEntry: Codable, Sendable, Hashable {
    var kind: SharedStateKind
    var scope: String
    var title: String
    var visibility: SharedStateVisibility
    var mutability: SharedStateMutability
    var lifetime: SharedStateLifetime
    var supersedes: [UUID]

    var decision: SharedDecisionState?
    var fact: SharedFactState?
    var artifactRef: SharedArtifactRefState?
    var issue: SharedIssueState?
    var resource: SharedResourceState?
}

struct StepSharedStateDelta: Codable, Sendable {
    var version: Int
    var rootSessionID: UUID?
    var roundIndex: Int?
    var stepID: UUID
    var stepName: String
    var entries: [ProposedSharedStateEntry]

    init(
        version: Int = 1,
        rootSessionID: UUID? = nil,
        roundIndex: Int? = nil,
        stepID: UUID,
        stepName: String,
        entries: [ProposedSharedStateEntry]
    ) {
        self.version = version
        self.rootSessionID = rootSessionID
        self.roundIndex = roundIndex
        self.stepID = stepID
        self.stepName = stepName
        self.entries = entries
    }
}

struct SharedStateSnapshot: Codable, Sendable {
    var rootSessionID: UUID
    var roundIndex: Int
    var waveIndex: Int
    var createdAt: Date
    var entries: [SharedStateEntry]
}

struct SharedStateConflict: Codable, Sendable, Hashable {
    var scope: String
    var existingEntryID: UUID
    var incomingStepID: UUID
    var message: String
}

struct SharedStateMergeOutcome: Codable, Sendable {
    var activatedEntryIDs: [UUID]
    var supersededEntryIDs: [UUID]
    var conflicts: [SharedStateConflict]
    var validationErrors: [String]

    static let empty = SharedStateMergeOutcome(
        activatedEntryIDs: [],
        supersededEntryIDs: [],
        conflicts: [],
        validationErrors: []
    )
}

struct SharedStateExecutionContext: Codable, Sendable, Hashable {
    var rootSessionID: UUID
    var roundIndex: Int
    var orchestrationMode: OrchestrationMode
}

struct SharedStateBudget: Sendable {
    var maxBriefEntries: Int
    var maxEntryChars: Int
    var maxPromptChars: Int
    var maxMirrorChars: Int
    var maxFallbackArtifactsPerStep: Int
    var maxFallbackIssuesPerStep: Int
    var maxFallbackDecisionsPerStep: Int
    var maxFallbackFactsPerStep: Int

    static let `default` = SharedStateBudget(
        maxBriefEntries: 8,
        maxEntryChars: 420,
        maxPromptChars: 4_000,
        maxMirrorChars: 120_000,
        maxFallbackArtifactsPerStep: 6,
        maxFallbackIssuesPerStep: 1,
        maxFallbackDecisionsPerStep: 4,
        maxFallbackFactsPerStep: 4
    )
}
