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

    struct ModeAnalyticsDailyPoint: Identifiable {
        let dayStart: Date
        let shownCount: Int
        let acceptedCount: Int
        let dismissedCount: Int
        let runtimeSwitchCount: Int

        var id: Date { dayStart }

        var acceptanceRate: Double {
            guard shownCount > 0 else { return 0 }
            return Double(acceptedCount) / Double(shownCount)
        }
    }

    struct ModeRecommendationPipelineSummary: Sendable {
        let recommendedAgentCount: Int
        let recommendedPipelineCount: Int
        let comparedPipelineCount: Int
        let matchedPipelineCount: Int
        let currentAgentCount: Int
        let currentPipelineCount: Int

        var totalRecommendedCount: Int {
            recommendedAgentCount + recommendedPipelineCount
        }

        var matchRate: Double {
            guard comparedPipelineCount > 0 else { return 0 }
            return Double(matchedPipelineCount) / Double(comparedPipelineCount)
        }
    }

    struct ModeRecommendationDailyPoint: Identifiable {
        let dayStart: Date
        let recommendedAgentCount: Int
        let recommendedPipelineCount: Int

        var id: Date { dayStart }
    }

    struct ModeRecommendationPipelineRow: Identifiable {
        let pipelineID: UUID
        let pipelineName: String
        let workingDirectory: String
        let recommendedMode: OrchestrationMode
        let currentMode: OrchestrationMode?
        let firstRecommendedAt: Date
        let latestRunStatus: PipelineRunStatus?
        let latestRunFinishedAt: Date?
        let totalRunDuration: TimeInterval?

        var id: UUID { pipelineID }

        var isMatched: Bool? {
            guard let currentMode else { return nil }
            return currentMode == recommendedMode
        }
    }

    private enum QueueBlockReason {
        case capacity
        case workingDirectoryLocked
        case legacyExecution

        var message: String {
            switch self {
            case .capacity:
                return "Queued: max concurrent runs reached."
            case .workingDirectoryLocked:
                return "Queued: another run is using the same working directory."
            case .legacyExecution:
                return "Queued: waiting for current exclusive execution to finish."
            }
        }
    }

    private enum QueuedRunKind {
        case mode(OrchestrationMode)
        case retry(
            retrySnapshot: Pipeline,
            baselinePipeline: Pipeline,
            resetStepIDs: Set<UUID>,
            cancelledMessage: String
        )
        case resumeAgent(
            instruction: String,
            expectedSessionID: UUID
        )

        var orchestrationMode: OrchestrationMode {
            switch self {
            case .mode(let mode):
                return mode
            case .retry:
                return .pipeline
            case .resumeAgent:
                return .agent
            }
        }
    }

    private struct QueuedRunRequest {
        let id: UUID
        let pipelineID: UUID
        let kind: QueuedRunKind
        let workingDirectoryKey: String
        let reason: QueueBlockReason
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
    @Published var activeOrchestrationMode: OrchestrationMode = .pipeline
    @Published var activeAgentSession: AgentSessionState?
    @Published var latestAgentSessionByPipeline: [UUID: AgentSessionState] = [:]
    @Published var mutedRuntimeModeSuggestions: Set<UUID> = []
    @Published private(set) var modeAnalyticsEvents: [ModeAnalyticsEvent] = []
    @Published var currentWave = 0
    @Published var isStopRequested = false
    @Published var stageStopRequests: Set<UUID> = []
    @Published var showFlowchart = false

    @Published var llmConfig = LLMConfig.defaultAgent {
        didSet { saveLLMConfig() }
    }
    @Published var isPlanningInProgress = false
    @Published var planningError: String?
    @Published var planningPhase: PlanningPhase?
    @Published var planningLogs: String = ""
    @Published var executionNotificationSettings = ExecutionNotificationSettings.default {
        didSet { saveExecutionNotificationSettings() }
    }
    @Published private(set) var executionNotificationAuthorizationState: ExecutionNotificationAuthorizationState = .notDetermined
    @Published var maxConcurrentPipelineRuns: Int = 2 {
        didSet {
            let clamped = max(minConcurrentPipelineRuns, min(maxConcurrentPipelineRuns, maxConcurrentPipelineRunsCap))
            if clamped != maxConcurrentPipelineRuns {
                maxConcurrentPipelineRuns = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.maxConcurrentPipelineRunsDefaultsKey)
            drainQueuedRunsIfPossible()
        }
    }
    @Published private(set) var queuedPipelineIDs: Set<UUID> = []
    @Published private(set) var queuedPipelineReasonByID: [UUID: String] = [:]
    @Published private(set) var activePipelineIDs: Set<UUID> = []
    @Published private(set) var stopRequestedPipelineIDs: Set<UUID> = []
    @Published private(set) var stageStopRequestsByPipelineID: [UUID: Set<UUID>] = [:]

    // MARK: - Private

    private let scheduler = DAGScheduler()
    private let planner = AIPlanner()
    private let maxRunHistoryPerPipeline = 3
    private let maxStoredStepOutputLength = 120_000
    private let maxIssueSummaryLength = 5_000
    private let maxIssueFailedStepsInSummary = 3
    private let maxIssueStepExcerptLength = 1_600
    private let maxIssueDependencyExcerptLength = 500
    private let maxIssueDependenciesPerStep = 2
    private let maxPlanningLogLength = 80_000
    private let defaultAgentMaxRounds = 4
    private let recommendationStrongThreshold = 65
    private let recommendationWeakThreshold = 40
    private let runtimeSuggestionCooldownMinutes = 10
    private let maxRuntimeSuggestionsPerSession = 2
    private let maxModeAnalyticsEvents = 500
    private let maxDeliveredExecutionNotificationKeys = 200
    private let notificationService = ExecutionNotificationService.shared
    private let minConcurrentPipelineRuns = 1
    private let maxConcurrentPipelineRunsCap = 4
    private var executionControl: ExecutionControl?
    private var executionControlByPipelineID: [UUID: ExecutionControl] = [:]
    private var activeOrchestrationModeByPipelineID: [UUID: OrchestrationMode] = [:]
    private var activeWorkingDirectoryKeyByPipelineID: [UUID: String] = [:]
    private var queuedRunRequests: [QueuedRunRequest] = []
    private var lastTrackedRecommendationKeyByPipeline: [UUID: String] = [:]
    private var lastTrackedRuntimeSuggestionKeyByPipeline: [UUID: String] = [:]
    private var runtimeSuggestionLastShownAt: [UUID: Date] = [:]
    private var runtimeSuggestionShownCount: [UUID: Int] = [:]
    private var deliveredExecutionNotificationKeys: [String] = []
    private var deliveredExecutionNotificationKeySet: Set<String> = []

    private struct SnapshotExecutionOutcome {
        let runID: UUID?
        let status: PipelineRunStatus
        let errorMessage: String?
    }

    private struct AgentEvaluationResult {
        let decision: AgentDecision
        let summary: String
        let reasons: [String]
        let nextRoundStrategy: AgentRepairStrategy?
    }

    private struct PlannedAgentRound {
        let pipeline: Pipeline
        let strategy: AgentRepairStrategy
        let summary: String
    }

    enum ModeSwitchSource {
        case manual
        case preRunRecommendation
        case runtimeSuggestion
    }

    private enum NotificationTestError: LocalizedError {
        case notificationsDisabled
        case authorizationRequired

        var errorDescription: String? {
            switch self {
            case .notificationsDisabled:
                return "Execution notifications are disabled."
            case .authorizationRequired:
                return "Notification permission is not granted for AgentCrew."
            }
        }
    }

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

    var modeAnalyticsLogURL: URL {
        Self.modeAnalyticsLogFileURL
    }

    var modeAnalyticsLogPath: String {
        modeAnalyticsLogURL.path
    }

    var modeAnalyticsEventTypeCounts: [ModeAnalyticsEventType: Int] {
        var counts: [ModeAnalyticsEventType: Int] = [:]
        for event in modeAnalyticsEvents {
            counts[event.type, default: 0] += 1
        }
        return counts
    }

    var modeRecommendationShownCount: Int {
        modeAnalyticsEvents.filter { $0.type == .modeRecommendationShown }.count
    }

    var modeRecommendationAcceptedCount: Int {
        modeAnalyticsEvents.filter(isRecommendationAcceptedEvent).count
    }

    var modeRecommendationDismissedCount: Int {
        modeAnalyticsEvents.filter { $0.type == .modeRecommendationDismissed }.count
    }

    var modeRuntimeSwitchCount: Int {
        modeAnalyticsEvents.filter { $0.type == .modeSwitchedRuntime }.count
    }

    var modeRecommendationAcceptanceRate: Double {
        guard modeRecommendationShownCount > 0 else { return 0 }
        return Double(modeRecommendationAcceptedCount) / Double(modeRecommendationShownCount)
    }

    var modeRecommendationPipelineSummary: ModeRecommendationPipelineSummary {
        buildModeRecommendationPipelineSummary()
    }

    var modeRecommendationDailyTrendLast7Days: [ModeRecommendationDailyPoint] {
        buildModeRecommendationDailyTrend(days: 7)
    }

    var modeRecommendationPipelineRows: [ModeRecommendationPipelineRow] {
        buildModeRecommendationPipelineRows()
    }

    var modeAnalyticsDailyTrendLast7Days: [ModeAnalyticsDailyPoint] {
        buildModeAnalyticsDailyTrend(days: 7)
    }

    // MARK: - Init

    init() {
        let storedConcurrency = UserDefaults.standard.integer(forKey: Self.maxConcurrentPipelineRunsDefaultsKey)
        if storedConcurrency > 0 {
            maxConcurrentPipelineRuns = storedConcurrency
        }
        loadPipelines()
        loadLLMConfig()
        loadModeAnalyticsEvents()
        loadExecutionNotificationSettings()
        Task { [weak self] in
            await self?.notificationService.configureForegroundPresentation()
            await self?.refreshExecutionNotificationAuthorizationState()
        }
    }

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
        guard !isPipelineQueued(id) else { return }
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

    // MARK: - Mode Selection

    func preferredRunMode(for pipelineID: UUID) -> OrchestrationMode {
        pipelines.first(where: { $0.id == pipelineID })?.preferredRunMode ?? .pipeline
    }

    func setPreferredRunMode(
        _ mode: OrchestrationMode,
        for pipelineID: UUID,
        source: ModeSwitchSource = .manual
    ) {
        guard !isPipelineExecuting(pipelineID) else { return }
        guard !isPipelineQueued(pipelineID) else { return }
        guard let index = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        let previousMode = pipelines[index].preferredRunMode
        pipelines[index].preferredRunMode = mode
        if mode == .agent {
            mutedRuntimeModeSuggestions.remove(pipelineID)
            runtimeSuggestionLastShownAt[pipelineID] = nil
            runtimeSuggestionShownCount[pipelineID] = 0
            lastTrackedRuntimeSuggestionKeyByPipeline[pipelineID] = nil
        }
        if previousMode != mode {
            if source != .manual {
                trackModeAnalyticsEvent(
                    .modeRecommendationAccepted,
                    pipelineID: pipelineID,
                    payload: [
                        "from": previousMode.rawValue,
                        "to": mode.rawValue,
                        "source": analyticsSourceName(source)
                    ]
                )
            }
            if source == .runtimeSuggestion {
                trackModeAnalyticsEvent(
                    .modeSwitchedRuntime,
                    pipelineID: pipelineID,
                    payload: [
                        "from": previousMode.rawValue,
                        "to": mode.rawValue
                    ]
                )
            }
        }
        savePipelines()
    }

    func acceptRuntimeSwitchSuggestion(for pipelineID: UUID) {
        setPreferredRunMode(.agent, for: pipelineID, source: .runtimeSuggestion)
    }

    func latestAgentSession(for pipelineID: UUID) -> AgentSessionState? {
        latestAgentSessionByPipeline[pipelineID]
    }

    func executeSelectedMode(for pipeline: Pipeline) async {
        submitModeRunRequest(
            pipelineID: pipeline.id,
            mode: preferredRunMode(for: pipeline.id)
        )
    }

    func isPipelineQueued(_ pipelineID: UUID) -> Bool {
        queuedPipelineIDs.contains(pipelineID)
    }

    func queuedReason(for pipelineID: UUID) -> String? {
        queuedPipelineReasonByID[pipelineID]
    }

    func modeRecommendation(for pipeline: Pipeline) -> ModeRecommendation {
        var score = 0
        var reasons: [String] = []

        let stageCount = pipeline.stages.count
        let stepCount = pipeline.allSteps.count
        let textCorpus = ([pipeline.name] + pipeline.allSteps.flatMap { [$0.name, $0.prompt] })
            .joined(separator: " ")
            .lowercased()
        let toolsUsed = Set(pipeline.allSteps.map { $0.displayTool ?? $0.tool })

        let hasComplexitySignal = stageCount >= 3 || stepCount >= 6
        if hasComplexitySignal {
            score += 15
            reasons.append("Task complexity is high (\(stageCount) stages / \(stepCount) steps).")
        }

        let hasClosedLoop = hasClosedLoopPattern(in: textCorpus)
        if hasClosedLoop {
            score += 20
            reasons.append("Workflow includes implement -> review -> fix/verify loop.")
        }

        if containsAnyKeyword(
            in: textCorpus,
            keywords: ["explore", "evaluation", "evaluate", "maybe", "try", "attempt", "探索", "评估", "可能", "尝试"]
        ) {
            score += 10
            reasons.append("Prompt includes uncertainty signals that often require replanning.")
        }

        let hasHighRiskDomain = containsAnyKeyword(
            in: textCorpus,
            keywords: ["auth", "authentication", "jwt", "token", "permission", "security", "payment", "migration", "认证", "权限", "安全", "支付", "迁移"]
        )
        if hasHighRiskDomain {
            score += 20
            reasons.append("Task touches high-risk domain (auth/payment/migration/security).")
        }

        if toolsUsed.count >= 2 {
            score += 10
            reasons.append("Multiple tools are involved, which benefits from role-based orchestration.")
        }

        let failureRate = recentFailureRate(for: pipeline, limit: 5)
        if pipeline.runHistory.count >= 2, failureRate >= 0.4 {
            score += 15
            reasons.append("Recent Pipeline runs have a high failure rate (\(Int((failureRate * 100).rounded()))%).")
        }

        if pipeline.preferredRunMode == .pipeline, !pipeline.runHistory.isEmpty {
            score -= 20
            reasons.append("You currently prefer Pipeline mode.")
        }

        if consecutiveSuccessCount(for: pipeline) >= 3 {
            score -= 15
            reasons.append("Pipeline mode has been stable for this task recently.")
        }

        let hardTriggered = hasHighRiskDomain && hasClosedLoop
        let clampedScore = max(0, min(100, score))

        let recommendedMode: OrchestrationMode
        let strength: RecommendationStrength
        if hardTriggered || clampedScore >= recommendationStrongThreshold {
            recommendedMode = .agent
            strength = .strong
        } else if clampedScore >= recommendationWeakThreshold {
            recommendedMode = .agent
            strength = .weak
        } else {
            recommendedMode = .pipeline
            strength = .strong
        }

        var trimmedReasons = Array(reasons.prefix(3))
        if hardTriggered {
            trimmedReasons.insert(
                "Hard trigger: high-risk domain + review/fix loop suggests Agent mode.",
                at: 0
            )
        }
        trimmedReasons = Array(trimmedReasons.prefix(3))
        if trimmedReasons.isEmpty {
            trimmedReasons = recommendedMode == .agent
                ? ["Agent mode is safer for adaptive multi-round execution."]
                : ["Pipeline mode is sufficient for this deterministic workflow."]
        }

        return ModeRecommendation(
            recommendedMode: recommendedMode,
            score: clampedScore,
            strength: strength,
            hardTriggered: hardTriggered,
            reasons: trimmedReasons
        )
    }

    func runtimeSwitchSuggestion(for pipeline: Pipeline) -> RuntimeModeSuggestion? {
        guard preferredRunMode(for: pipeline.id) == .pipeline else { return nil }
        guard !mutedRuntimeModeSuggestions.contains(pipeline.id) else { return nil }
        guard let latestRun = pipeline.runHistory
            .sorted(by: { $0.startedAt > $1.startedAt })
            .first,
              latestRun.status == .failed
        else {
            return nil
        }

        var reasons: [String] = []
        let failedSteps = countFailedSteps(in: latestRun)
        if failedSteps >= 2 {
            reasons.append("Detected \(failedSteps) failed steps in latest run.")
        }
        if runContainsSeveritySignal(latestRun) {
            reasons.append("Reviewer output contains high/critical risk signals.")
        }
        if recentRunsFailingSameStage(in: pipeline, minOccurrences: 2) {
            reasons.append("Recent retries failed on the same stage.")
        }

        guard !reasons.isEmpty else { return nil }
        let suggestion = RuntimeModeSuggestion(
            suggestedMode: .agent,
            reasons: Array(reasons.prefix(3))
        )
        let key = "\(suggestion.suggestedMode.rawValue)|\(suggestion.reasons.joined(separator: "||"))"
        if lastTrackedRuntimeSuggestionKeyByPipeline[pipeline.id] == key {
            return suggestion
        }

        if runtimeSuggestionShownCount[pipeline.id, default: 0] >= maxRuntimeSuggestionsPerSession {
            return nil
        }
        if let lastShownAt = runtimeSuggestionLastShownAt[pipeline.id] {
            let cooldown = TimeInterval(runtimeSuggestionCooldownMinutes * 60)
            if Date().timeIntervalSince(lastShownAt) < cooldown {
                return nil
            }
        }
        return suggestion
    }

    func applyInitialAgentRecommendationIfNeeded(
        for pipelineID: UUID,
        recommendation: ModeRecommendation
    ) {
        guard recommendation.recommendedMode == .agent else { return }
        guard let pipeline = pipelines.first(where: { $0.id == pipelineID }) else { return }
        // Only auto-apply for fresh pipelines to avoid overriding established preferences.
        guard pipeline.runHistory.isEmpty else { return }
        guard pipeline.preferredRunMode == .pipeline else { return }
        setPreferredRunMode(.agent, for: pipelineID)
    }

    func markPreRunRecommendationShown(
        for pipelineID: UUID,
        recommendation: ModeRecommendation
    ) {
        let key = "\(recommendation.recommendedMode.rawValue)|\(recommendation.score)|\(recommendation.reasons.joined(separator: "||"))"
        guard lastTrackedRecommendationKeyByPipeline[pipelineID] != key else { return }
        lastTrackedRecommendationKeyByPipeline[pipelineID] = key
        trackModeAnalyticsEvent(
            .modeRecommendationShown,
            pipelineID: pipelineID,
            payload: [
                "source": "pre_run",
                "recommendedMode": recommendation.recommendedMode.rawValue,
                "score": String(recommendation.score),
                "strength": recommendation.strength.rawValue,
                "hardTriggered": recommendation.hardTriggered ? "true" : "false"
            ]
        )
    }

    func markRuntimeSuggestionShown(
        for pipelineID: UUID,
        suggestion: RuntimeModeSuggestion
    ) {
        let key = "\(suggestion.suggestedMode.rawValue)|\(suggestion.reasons.joined(separator: "||"))"
        guard lastTrackedRuntimeSuggestionKeyByPipeline[pipelineID] != key else { return }
        lastTrackedRuntimeSuggestionKeyByPipeline[pipelineID] = key
        runtimeSuggestionLastShownAt[pipelineID] = Date()
        runtimeSuggestionShownCount[pipelineID, default: 0] += 1
        trackModeAnalyticsEvent(
            .modeRecommendationShown,
            pipelineID: pipelineID,
            payload: [
                "source": "runtime",
                "recommendedMode": suggestion.suggestedMode.rawValue,
                "reasons": suggestion.reasons.joined(separator: " | ")
            ]
        )
    }

    func dismissRuntimeModeSuggestion(for pipelineID: UUID) {
        mutedRuntimeModeSuggestions.insert(pipelineID)
        trackModeAnalyticsEvent(
            .modeRecommendationDismissed,
            pipelineID: pipelineID,
            payload: ["source": "runtime"]
        )
    }

    // MARK: - Execution

    func executePipeline(_ pipeline: Pipeline) async {
        submitModeRunRequest(pipelineID: pipeline.id, mode: .pipeline)
    }

    func executeAgentSession(_ pipeline: Pipeline) async {
        submitModeRunRequest(pipelineID: pipeline.id, mode: .agent)
    }

    private func submitModeRunRequest(pipelineID: UUID, mode: OrchestrationMode) {
        submitRunRequest(
            pipelineID: pipelineID,
            kind: .mode(mode)
        )
    }

    private func submitRetryRunRequest(
        pipelineID: UUID,
        retrySnapshot: Pipeline,
        baselinePipeline: Pipeline,
        resetStepIDs: Set<UUID>,
        cancelledMessage: String
    ) {
        submitRunRequest(
            pipelineID: pipelineID,
            kind: .retry(
                retrySnapshot: retrySnapshot,
                baselinePipeline: baselinePipeline,
                resetStepIDs: resetStepIDs,
                cancelledMessage: cancelledMessage
            )
        )
    }

    private func submitResumeAgentRunRequest(
        pipelineID: UUID,
        instruction: String,
        expectedSessionID: UUID
    ) {
        submitRunRequest(
            pipelineID: pipelineID,
            kind: .resumeAgent(
                instruction: instruction,
                expectedSessionID: expectedSessionID
            )
        )
    }

    private func submitRunRequest(
        pipelineID: UUID,
        kind: QueuedRunKind
    ) {
        guard let pipeline = pipelines.first(where: { $0.id == pipelineID }) else { return }
        guard !isPipelineExecuting(pipelineID) else { return }
        guard !isPipelineQueued(pipelineID) else { return }

        let request = QueuedRunRequest(
            id: UUID(),
            pipelineID: pipelineID,
            kind: kind,
            workingDirectoryKey: normalizedWorkingDirectoryKey(pipeline.workingDirectory),
            reason: .capacity
        )

        if let reason = blockReasonForNewRun(request) {
            queueModeRunRequest(request, reason: reason)
            return
        }
        startModeRun(request)
    }

    private func blockReasonForNewRun(_ request: QueuedRunRequest) -> QueueBlockReason? {
        if isExecuting && activePipelineIDs.isEmpty {
            return .legacyExecution
        }

        let workingDirectoryKey = latestWorkingDirectoryKey(for: request)
        if !workingDirectoryKey.isEmpty {
            for activeKey in activeWorkingDirectoryKeyByPipelineID.values where workingDirectoryKeysConflict(activeKey, workingDirectoryKey) {
                return .workingDirectoryLocked
            }
        }

        if activePipelineIDs.count >= maxConcurrentPipelineRuns {
            return .capacity
        }
        return nil
    }

    private func queueModeRunRequest(_ request: QueuedRunRequest, reason: QueueBlockReason) {
        var queued = request
        queued = QueuedRunRequest(
            id: request.id,
            pipelineID: request.pipelineID,
            kind: request.kind,
            workingDirectoryKey: request.workingDirectoryKey,
            reason: reason
        )
        queuedRunRequests.append(queued)
        refreshQueuedPipelineState()
    }

    private func refreshQueuedPipelineState() {
        queuedPipelineIDs = Set(queuedRunRequests.map(\.pipelineID))
        var reasons: [UUID: String] = [:]
        for request in queuedRunRequests {
            reasons[request.pipelineID] = request.reason.message
        }
        queuedPipelineReasonByID = reasons
    }

    private func drainQueuedRunsIfPossible() {
        guard !(isExecuting && activePipelineIDs.isEmpty) else { return }
        guard !queuedRunRequests.isEmpty else {
            refreshQueuedPipelineState()
            return
        }

        var launched = true
        while launched && activePipelineIDs.count < maxConcurrentPipelineRuns {
            launched = false
            for index in queuedRunRequests.indices {
                let request = queuedRunRequests[index]
                if blockReasonForNewRun(request) == nil {
                    let removed = queuedRunRequests.remove(at: index)
                    refreshQueuedPipelineState()
                    startModeRun(removed)
                    launched = true
                    break
                } else {
                    if let reason = blockReasonForNewRun(request) {
                        queuedRunRequests[index] = QueuedRunRequest(
                            id: request.id,
                            pipelineID: request.pipelineID,
                            kind: request.kind,
                            workingDirectoryKey: request.workingDirectoryKey,
                            reason: reason
                        )
                    }
                }
            }
        }
        refreshQueuedPipelineState()
    }

    private func startModeRun(_ request: QueuedRunRequest) {
        let workingDirectoryKey = latestWorkingDirectoryKey(for: request)
        activePipelineIDs.insert(request.pipelineID)
        activeOrchestrationModeByPipelineID[request.pipelineID] = request.kind.orchestrationMode
        activeWorkingDirectoryKeyByPipelineID[request.pipelineID] = workingDirectoryKey
        stopRequestedPipelineIDs.remove(request.pipelineID)
        stageStopRequestsByPipelineID[request.pipelineID] = []
        isExecuting = true
        executingPipelineID = request.pipelineID
        activeOrchestrationMode = request.kind.orchestrationMode
        currentWave = 0

        Task { [weak self] in
            guard let self else { return }
            defer { self.finishModeRun(pipelineID: request.pipelineID) }

            switch request.kind {
            case .mode(let mode):
                switch mode {
                case .pipeline:
                    await self.executePipelineNow(pipelineID: request.pipelineID)
                case .agent:
                    await self.executeAgentSessionNow(pipelineID: request.pipelineID)
                }
            case .retry(let retrySnapshot, let baselinePipeline, let resetStepIDs, let cancelledMessage):
                await self.executeRetrySnapshot(
                    retrySnapshot,
                    for: baselinePipeline,
                    rootPipelineID: request.pipelineID,
                    resetStepIDs: resetStepIDs,
                    cancelledMessage: cancelledMessage
                )
            case .resumeAgent(let instruction, let expectedSessionID):
                await self.executeResumedAgentSessionNow(
                    pipelineID: request.pipelineID,
                    instruction: instruction,
                    expectedSessionID: expectedSessionID
                )
            }
        }
    }

    private func finishModeRun(pipelineID: UUID) {
        executionControlByPipelineID.removeValue(forKey: pipelineID)
        activePipelineIDs.remove(pipelineID)
        activeOrchestrationModeByPipelineID.removeValue(forKey: pipelineID)
        activeWorkingDirectoryKeyByPipelineID.removeValue(forKey: pipelineID)
        stopRequestedPipelineIDs.remove(pipelineID)
        stageStopRequestsByPipelineID.removeValue(forKey: pipelineID)

        if activePipelineIDs.isEmpty {
            isExecuting = false
            executingPipelineID = nil
            activeOrchestrationMode = .pipeline
        } else if let nextID = activePipelineIDs.first {
            executingPipelineID = nextID
            activeOrchestrationMode = activeOrchestrationModeByPipelineID[nextID] ?? .pipeline
        }
        drainQueuedRunsIfPossible()
    }

    private func normalizedWorkingDirectoryKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return resolved.lowercased()
    }

    private func latestWorkingDirectoryKey(for request: QueuedRunRequest) -> String {
        if case .retry(let retrySnapshot, _, _, _) = request.kind {
            return normalizedWorkingDirectoryKey(retrySnapshot.workingDirectory)
        }
        guard let pipeline = pipelines.first(where: { $0.id == request.pipelineID }) else {
            return request.workingDirectoryKey
        }
        return normalizedWorkingDirectoryKey(pipeline.workingDirectory)
    }

    private func workingDirectoryKeysConflict(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        return lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private func executePipelineNow(pipelineID: UUID) async {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        let pipelineSnapshot = pipelines[pipelineIndex]

        executionError = nil
        mutedRuntimeModeSuggestions.remove(pipelineID)
        runtimeSuggestionLastShownAt[pipelineID] = nil
        runtimeSuggestionShownCount[pipelineID] = 0
        lastTrackedRuntimeSuggestionKeyByPipeline[pipelineID] = nil

        for step in pipelineSnapshot.allSteps {
            stepStatuses[step.id] = .pending
            stepOutputs[step.id] = nil
        }

        let control = ExecutionControl()
        executionControlByPipelineID[pipelineID] = control
        defer { executionControlByPipelineID.removeValue(forKey: pipelineID) }

        let pipelineRunStartedAt = Date()
        let runID = startRunRecord(
            for: pipelineID,
            orchestrationMode: .pipeline
        )
        let rootSessionID = runID ?? UUID()
        let ref = WeakVM(vm: self)
        var finalRunStatus: PipelineRunStatus = .completed
        var finalErrorMessage: String?

        do {
            _ = try await scheduler.executePipeline(
                pipelineSnapshot,
                sharedStateExecutionContext: SharedStateExecutionContext(
                    rootSessionID: rootSessionID,
                    roundIndex: 0,
                    orchestrationMode: .pipeline
                ),
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
                let finishedAt = Date()
                finalizeRunRecord(
                    pipelineID: pipelineID,
                    runID: runID,
                    status: .completed,
                    errorMessage: nil,
                    finishedAt: finishedAt
                )
            }
        } catch {
            let runStatus: PipelineRunStatus
            let message: String
            if let schedulerError = error as? SchedulerError {
                switch schedulerError {
                case .cancelled:
                    message = "Pipeline stopped by user."
                    runStatus = .cancelled
                default:
                    message = error.localizedDescription
                    runStatus = .failed
                }
            } else {
                message = error.localizedDescription
                runStatus = .failed
            }
            executionError = message
            finalRunStatus = runStatus
            finalErrorMessage = message
            if let runID {
                let finishedAt = Date()
                finalizeRunRecord(
                    pipelineID: pipelineID,
                    runID: runID,
                    status: runStatus,
                    errorMessage: message,
                    finishedAt: finishedAt
                )
            }
        }

        trackModeAnalyticsEvent(
            .taskOutcomeByMode,
            pipelineID: pipelineID,
            payload: [
                "mode": OrchestrationMode.pipeline.rawValue,
                "status": finalRunStatus.rawValue
            ]
        )
        savePipelines()
        await postExecutionCompletionNotificationIfNeeded(
            pipelineID: pipelineID,
            pipelineName: pipelineSnapshot.name,
            mode: .pipeline,
            status: finalRunStatus,
            dedupID: runID,
            startedAt: pipelineRunStartedAt,
            finishedAt: Date(),
            errorMessage: finalErrorMessage
        )
    }

    private func executeAgentSessionNow(pipelineID: UUID) async {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        let basePipeline = pipelines[pipelineIndex]

        executionError = nil
        mutedRuntimeModeSuggestions.remove(pipelineID)
        runtimeSuggestionLastShownAt[pipelineID] = nil
        runtimeSuggestionShownCount[pipelineID] = 0
        lastTrackedRuntimeSuggestionKeyByPipeline[pipelineID] = nil

        var session = AgentSessionState(
            pipelineID: pipelineID,
            status: .created,
            startedAt: Date(),
            currentRound: 0,
            maxRounds: defaultAgentMaxRounds
        )
        publishAgentSession(session)

        var previousRun: PipelineRunRecord?
        var previousError: String?
        var finished = false
        var nextRoundStrategy: AgentRepairStrategy = .originalPipeline

        roundLoop: for roundIndex in 1...defaultAgentMaxRounds {
            if isPipelineStopRequested(pipelineID) {
                session.status = .cancelled
                session.failureMessage = "Agent run stopped by user."
                session.latestDecision = .abort
                session.endedAt = Date()
                executionError = session.failureMessage
                publishAgentSession(session)
                break roundLoop
            }

            session.currentRound = roundIndex
            session.status = .planning
            let plannedRound = buildAgentRound(
                strategy: nextRoundStrategy,
                basePipeline: basePipeline,
                roundIndex: roundIndex,
                previousRun: previousRun,
                previousError: previousError,
                humanInstruction: nil
            )
            let plannedPipeline = plannedRound.pipeline
            let roundStrategy = plannedRound.strategy

            session.rounds.append(
                AgentRoundState(
                    index: roundIndex,
                    planName: plannedPipeline.name,
                    strategy: roundStrategy,
                    summary: plannedRound.summary
                )
            )
            publishAgentSession(session)

            session.status = .executing
            session.rounds[session.rounds.count - 1].startedAt = Date()
            publishAgentSession(session)

            let control = ExecutionControl()
            executionControlByPipelineID[pipelineID] = control
            let outcome = await executePipelineSnapshot(
                plannedPipeline,
                rootPipelineID: pipelineID,
                rootSessionID: session.id,
                control: control,
                roundIndex: roundIndex,
                strategy: roundStrategy
            )
            executionControlByPipelineID.removeValue(forKey: pipelineID)

            session.rounds[session.rounds.count - 1].endedAt = Date()
            session.rounds[session.rounds.count - 1].runStatus = outcome.status

            previousError = outcome.errorMessage
            if let runID = outcome.runID,
               let run = runRecord(pipelineID: pipelineID, runID: runID) {
                previousRun = run
                updateCoverageContract(
                    session: &session,
                    run: run,
                    roundIndex: roundIndex,
                    strategy: roundStrategy,
                    basePipeline: basePipeline
                )
                recordRunCoverageSnapshot(
                    pipelineID: pipelineID,
                    runID: runID,
                    coverageItems: session.coverageItems
                )
            }

            session.status = .evaluating
            publishAgentSession(session)

            var evaluation = evaluateAgentDecision(
                latestRun: previousRun,
                pipelineID: pipelineID,
                roundIndex: roundIndex,
                maxRounds: defaultAgentMaxRounds,
                fallbackError: outcome.errorMessage,
                currentStrategy: roundStrategy,
                basePipeline: basePipeline
            )
            evaluation = enforceCoverageContract(
                evaluation: evaluation,
                session: session,
                roundIndex: roundIndex,
                maxRounds: defaultAgentMaxRounds
            )

            session.rounds[session.rounds.count - 1].decision = evaluation.decision
            session.rounds[session.rounds.count - 1].reasons = evaluation.reasons
            session.rounds[session.rounds.count - 1].summary = evaluation.summary
            session.latestDecision = evaluation.decision
            if let nextStrategy = evaluation.nextRoundStrategy {
                nextRoundStrategy = nextStrategy
            }
            publishAgentSession(session)

            switch evaluation.decision {
            case .finish:
                session.status = .completed
                session.endedAt = Date()
                executionError = nil
                finished = true
                publishAgentSession(session)
                break roundLoop

            case .replan:
                if roundIndex >= defaultAgentMaxRounds {
                    session.status = .failed
                    session.failureMessage = "Agent reached max rounds (\(defaultAgentMaxRounds)) without a stable result."
                    session.endedAt = Date()
                    executionError = session.failureMessage
                    publishAgentSession(session)
                    break roundLoop
                }
                continue roundLoop

            case .askHuman:
                session.status = .waitingHuman
                session.failureMessage = evaluation.summary
                session.endedAt = Date()
                executionError = evaluation.summary
                publishAgentSession(session)
                break roundLoop

            case .abort:
                session.status = isPipelineStopRequested(pipelineID) ? .cancelled : .failed
                session.failureMessage = evaluation.summary
                session.endedAt = Date()
                executionError = evaluation.summary
                publishAgentSession(session)
                break roundLoop

            case .continue:
                continue roundLoop
            }
        }

        if !finished,
           session.status != .failed,
           session.status != .cancelled,
           session.status != .waitingHuman {
            session.status = .failed
            session.failureMessage = "Agent run ended unexpectedly."
            session.endedAt = Date()
            executionError = session.failureMessage
            publishAgentSession(session)
        }

        latestAgentSessionByPipeline[pipelineID] = session
        if activeAgentSession?.pipelineID == pipelineID {
            activeAgentSession = nil
        }

        trackModeAnalyticsEvent(
            .taskOutcomeByMode,
            pipelineID: pipelineID,
            payload: [
                "mode": OrchestrationMode.agent.rawValue,
                "status": session.status.rawValue,
                "rounds": String(session.currentRound)
            ]
        )
        savePipelines()
        if let notificationStatus = pipelineRunStatus(from: session.status) {
            await postExecutionCompletionNotificationIfNeeded(
                pipelineID: pipelineID,
                pipelineName: basePipeline.name,
                mode: .agent,
                status: notificationStatus,
                dedupID: session.id,
                startedAt: session.startedAt,
                finishedAt: session.endedAt ?? Date(),
                errorMessage: session.failureMessage
            )
        }
    }

    func resumeAgentSessionAfterHumanApproval(
        for pipeline: Pipeline,
        instruction: String
    ) async {
        guard let session = latestAgentSessionByPipeline[pipeline.id],
              session.status == .waitingHuman
        else { return }
        submitResumeAgentRunRequest(
            pipelineID: pipeline.id,
            instruction: instruction,
            expectedSessionID: session.id
        )
    }

    private func executeResumedAgentSessionNow(
        pipelineID: UUID,
        instruction: String,
        expectedSessionID: UUID
    ) async {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        let basePipeline = pipelines[pipelineIndex]
        guard var session = latestAgentSessionByPipeline[pipelineID],
              session.status == .waitingHuman,
              session.id == expectedSessionID
        else {
            return
        }

        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        executionError = nil
        session.status = .planning
        session.failureMessage = nil
        session.endedAt = nil
        publishAgentSession(session)

        let startRound = session.currentRound + 1
        guard startRound <= session.maxRounds else {
            session.status = .failed
            session.failureMessage = "Agent cannot resume because max rounds (\(session.maxRounds)) has been reached."
            session.endedAt = Date()
            executionError = session.failureMessage
            publishAgentSession(session)
            latestAgentSessionByPipeline[pipelineID] = session
            savePipelines()
            return
        }

        var previousRun: PipelineRunRecord? = pipelines[pipelineIndex].runHistory
            .sorted(by: { $0.startedAt > $1.startedAt })
            .first
        var previousError: String? = previousRun?.errorMessage
        var finished = false
        var nextRoundStrategy: AgentRepairStrategy = .globalReplan

        roundLoop: for roundIndex in startRound...session.maxRounds {
            if isPipelineStopRequested(pipelineID) {
                session.status = .cancelled
                session.failureMessage = "Agent run stopped by user."
                session.latestDecision = .abort
                session.endedAt = Date()
                executionError = session.failureMessage
                publishAgentSession(session)
                break roundLoop
            }

            session.currentRound = roundIndex
            session.status = .planning
            let injectedInstruction = (roundIndex == startRound && !trimmedInstruction.isEmpty)
                ? trimmedInstruction
                : nil
            let plannedRound = buildAgentRound(
                strategy: nextRoundStrategy,
                basePipeline: basePipeline,
                roundIndex: roundIndex,
                previousRun: previousRun,
                previousError: previousError,
                humanInstruction: injectedInstruction
            )
            let plannedPipeline = plannedRound.pipeline
            let roundStrategy = plannedRound.strategy

            session.rounds.append(
                AgentRoundState(
                    index: roundIndex,
                    planName: plannedPipeline.name,
                    strategy: roundStrategy,
                    summary: plannedRound.summary
                )
            )
            publishAgentSession(session)

            session.status = .executing
            session.rounds[session.rounds.count - 1].startedAt = Date()
            publishAgentSession(session)

            let control = ExecutionControl()
            executionControlByPipelineID[pipelineID] = control
            let outcome = await executePipelineSnapshot(
                plannedPipeline,
                rootPipelineID: pipelineID,
                rootSessionID: session.id,
                control: control,
                roundIndex: roundIndex,
                strategy: roundStrategy
            )
            executionControlByPipelineID.removeValue(forKey: pipelineID)

            session.rounds[session.rounds.count - 1].endedAt = Date()
            session.rounds[session.rounds.count - 1].runStatus = outcome.status

            previousError = outcome.errorMessage
            if let runID = outcome.runID,
               let run = runRecord(pipelineID: pipelineID, runID: runID) {
                previousRun = run
                updateCoverageContract(
                    session: &session,
                    run: run,
                    roundIndex: roundIndex,
                    strategy: roundStrategy,
                    basePipeline: basePipeline
                )
                recordRunCoverageSnapshot(
                    pipelineID: pipelineID,
                    runID: runID,
                    coverageItems: session.coverageItems
                )
            }

            session.status = .evaluating
            publishAgentSession(session)

            var evaluation = evaluateAgentDecision(
                latestRun: previousRun,
                pipelineID: pipelineID,
                roundIndex: roundIndex,
                maxRounds: session.maxRounds,
                fallbackError: outcome.errorMessage,
                currentStrategy: roundStrategy,
                basePipeline: basePipeline
            )
            evaluation = enforceCoverageContract(
                evaluation: evaluation,
                session: session,
                roundIndex: roundIndex,
                maxRounds: session.maxRounds
            )

            session.rounds[session.rounds.count - 1].decision = evaluation.decision
            session.rounds[session.rounds.count - 1].reasons = evaluation.reasons
            session.rounds[session.rounds.count - 1].summary = evaluation.summary
            session.latestDecision = evaluation.decision
            if let nextStrategy = evaluation.nextRoundStrategy {
                nextRoundStrategy = nextStrategy
            }
            publishAgentSession(session)

            switch evaluation.decision {
            case .finish:
                session.status = .completed
                session.endedAt = Date()
                executionError = nil
                finished = true
                publishAgentSession(session)
                break roundLoop

            case .replan:
                if roundIndex >= session.maxRounds {
                    session.status = .failed
                    session.failureMessage = "Agent reached max rounds (\(session.maxRounds)) without a stable result."
                    session.endedAt = Date()
                    executionError = session.failureMessage
                    publishAgentSession(session)
                    break roundLoop
                }
                continue roundLoop

            case .askHuman:
                session.status = .waitingHuman
                session.failureMessage = evaluation.summary
                session.endedAt = Date()
                executionError = evaluation.summary
                publishAgentSession(session)
                break roundLoop

            case .abort:
                session.status = isPipelineStopRequested(pipelineID) ? .cancelled : .failed
                session.failureMessage = evaluation.summary
                session.endedAt = Date()
                executionError = evaluation.summary
                publishAgentSession(session)
                break roundLoop

            case .continue:
                continue roundLoop
            }
        }

        if !finished,
           session.status != .failed,
           session.status != .cancelled,
           session.status != .waitingHuman {
            session.status = .failed
            session.failureMessage = "Resumed agent run ended unexpectedly."
            session.endedAt = Date()
            executionError = session.failureMessage
            publishAgentSession(session)
        }

        latestAgentSessionByPipeline[pipelineID] = session
        if activeAgentSession?.pipelineID == pipelineID {
            activeAgentSession = nil
        }

        trackModeAnalyticsEvent(
            .taskOutcomeByMode,
            pipelineID: pipelineID,
            payload: [
                "mode": OrchestrationMode.agent.rawValue,
                "status": session.status.rawValue,
                "rounds": String(session.currentRound),
                "resumed": "true"
            ]
        )
        savePipelines()
        if let notificationStatus = pipelineRunStatus(from: session.status) {
            await postExecutionCompletionNotificationIfNeeded(
                pipelineID: pipelineID,
                pipelineName: basePipeline.name,
                mode: .agent,
                status: notificationStatus,
                dedupID: session.id,
                startedAt: session.startedAt,
                finishedAt: session.endedAt ?? Date(),
                errorMessage: session.failureMessage
            )
        }
    }

    func abortWaitingAgentSession(for pipelineID: UUID) {
        guard var session = latestAgentSessionByPipeline[pipelineID],
              session.status == .waitingHuman
        else { return }
        queuedRunRequests.removeAll { request in
            guard request.pipelineID == pipelineID else { return false }
            if case .resumeAgent = request.kind {
                return true
            }
            return false
        }
        refreshQueuedPipelineState()
        session.status = .cancelled
        session.latestDecision = .abort
        session.failureMessage = "Agent session cancelled by user while waiting for confirmation."
        session.endedAt = Date()
        executionError = session.failureMessage
        publishAgentSession(session)
        trackModeAnalyticsEvent(
            .taskOutcomeByMode,
            pipelineID: pipelineID,
            payload: [
                "mode": OrchestrationMode.agent.rawValue,
                "status": session.status.rawValue,
                "cancelledWhileWaitingHuman": "true"
            ]
        )
    }

    func retryStage(_ stageID: UUID, in pipelineID: UUID) async {
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

        submitRetryRunRequest(
            pipelineID: pipelineID,
            retrySnapshot: retrySnapshot,
            baselinePipeline: pipelines[pipelineIndex],
            resetStepIDs: Set(retryStage.steps.map(\.id)),
            cancelledMessage: "Stage retry stopped by user."
        )
    }

    func retryStep(_ stepID: UUID, in pipelineID: UUID) async {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }

        let pipeline = pipelines[pipelineIndex]
        guard let stageIndex = pipeline.stages.firstIndex(where: { stage in
            stage.steps.contains(where: { $0.id == stepID })
        }) else { return }
        guard let stepIndex = pipeline.stages[stageIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }

        var retryStage = pipeline.stages[stageIndex]
        var retryStep = retryStage.steps[stepIndex]
        retryStep.dependsOnStepIDs = []
        retryStage.steps = [retryStep]

        var retrySnapshot = pipeline
        retrySnapshot.stages = [retryStage]

        submitRetryRunRequest(
            pipelineID: pipelineID,
            retrySnapshot: retrySnapshot,
            baselinePipeline: pipeline,
            resetStepIDs: Set([stepID]),
            cancelledMessage: "Step retry stopped by user."
        )
    }

    func stopPipeline(_ pipelineID: UUID? = nil) {
        guard isExecuting else { return }
        let targetPipelineID = pipelineID ?? executingPipelineID
        guard let targetPipelineID else { return }

        if activePipelineIDs.contains(targetPipelineID) {
            stopRequestedPipelineIDs.insert(targetPipelineID)
            Task {
                await executionControlByPipelineID[targetPipelineID]?.requestPipelineStop()
            }
            return
        }

        guard executingPipelineID == targetPipelineID || pipelineID == nil else { return }
        isStopRequested = true
        Task {
            await executionControl?.requestPipelineStop()
        }
    }

    func stopStage(_ stageID: UUID, in pipelineID: UUID) {
        guard let pipeline = pipelines.first(where: { $0.id == pipelineID }),
              pipeline.stages.contains(where: { $0.id == stageID })
        else { return }

        if activePipelineIDs.contains(pipelineID) {
            stageStopRequestsByPipelineID[pipelineID, default: []].insert(stageID)
            Task {
                await executionControlByPipelineID[pipelineID]?.requestStageStop(stageID)
            }
            return
        }

        guard isExecuting else { return }
        guard executingPipelineID == pipelineID else { return }
        stageStopRequests.insert(stageID)
        Task {
            await executionControl?.requestStageStop(stageID)
        }
    }

    func isStageStopRequested(_ stageID: UUID, in pipelineID: UUID) -> Bool {
        if stageStopRequestsByPipelineID[pipelineID]?.contains(stageID) == true {
            return true
        }
        if executingPipelineID == pipelineID {
            return stageStopRequests.contains(stageID)
        }
        return false
    }

    func isStageStopRequested(_ stageID: UUID) -> Bool {
        if stageStopRequests.contains(stageID) {
            return true
        }
        return stageStopRequestsByPipelineID.values.contains { $0.contains(stageID) }
    }

    func isPipelineStopRequested(_ pipelineID: UUID) -> Bool {
        if stopRequestedPipelineIDs.contains(pipelineID) {
            return true
        }
        if executingPipelineID == pipelineID {
            return isStopRequested
        }
        return false
    }

    func isPipelineExecuting(_ pipelineID: UUID) -> Bool {
        if activePipelineIDs.contains(pipelineID) {
            return true
        }
        return isExecuting && activePipelineIDs.isEmpty && executingPipelineID == pipelineID
    }

    func isAgentExecuting(_ pipelineID: UUID) -> Bool {
        if activeOrchestrationModeByPipelineID[pipelineID] == .agent {
            return isPipelineExecuting(pipelineID)
        }
        return isPipelineExecuting(pipelineID) && activeOrchestrationMode == .agent
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

    // MARK: - Execution notifications

    func refreshExecutionNotificationAuthorizationState() async {
        executionNotificationAuthorizationState = await notificationService.authorizationState()
    }

    @discardableResult
    func setExecutionNotificationsEnabled(_ isEnabled: Bool) async -> Bool {
        if !isEnabled {
            executionNotificationSettings.isEnabled = false
            return true
        }

        let granted = await notificationService.requestAuthorizationIfNeeded()
        executionNotificationAuthorizationState = granted ? .authorized : .denied
        executionNotificationSettings.isEnabled = granted
        return granted
    }

    func sendExecutionNotificationTest() async throws {
        guard executionNotificationSettings.isEnabled else {
            throw NotificationTestError.notificationsDisabled
        }

        let authorizationState = await notificationService.authorizationState()
        executionNotificationAuthorizationState = authorizationState
        guard authorizationState == .authorized else {
            throw NotificationTestError.authorizationRequired
        }

        try await notificationService.sendLocalNotification(
            identifier: "agentcrew-test-\(UUID().uuidString)",
            title: "AgentCrew notification test",
            body: "Switch to another app now. This test notification fires in 3 seconds.",
            playSound: executionNotificationSettings.playSound,
            delaySeconds: 3
        )
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

    private func saveLLMConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(llmConfig) else { return }
        try? data.write(to: Self.llmConfigFileURL)
    }

    private func loadLLMConfig() {
        guard let data = try? Data(contentsOf: Self.llmConfigFileURL) else { return }
        let decoder = JSONDecoder()
        if let config = try? decoder.decode(LLMConfig.self, from: data) {
            llmConfig = config
        }
    }

    private func saveExecutionNotificationSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(executionNotificationSettings) else { return }
        try? data.write(to: Self.executionNotificationSettingsFileURL)
    }

    private func loadExecutionNotificationSettings() {
        guard let data = try? Data(contentsOf: Self.executionNotificationSettingsFileURL) else { return }
        let decoder = JSONDecoder()
        if let settings = try? decoder.decode(ExecutionNotificationSettings.self, from: data) {
            executionNotificationSettings = settings
        }
    }

    func exportModeAnalyticsLog(to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        if fileManager.fileExists(atPath: Self.modeAnalyticsLogFileURL.path) {
            try fileManager.copyItem(at: Self.modeAnalyticsLogFileURL, to: destinationURL)
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = modeAnalyticsEvents.compactMap { event -> String? in
            guard let data = try? encoder.encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let body = lines.joined(separator: "\n")
        try body.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    func clearModeAnalyticsLog() {
        modeAnalyticsEvents.removeAll()
        try? FileManager.default.removeItem(at: Self.modeAnalyticsLogFileURL)
    }

    private func loadModeAnalyticsEvents() {
        guard let data = try? Data(contentsOf: Self.modeAnalyticsLogFileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            modeAnalyticsEvents = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loadedEvents: [ModeAnalyticsEvent] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(ModeAnalyticsEvent.self, from: lineData)
            else {
                continue
            }
            loadedEvents.append(event)
        }

        if loadedEvents.count > maxModeAnalyticsEvents {
            loadedEvents = Array(loadedEvents.suffix(maxModeAnalyticsEvents))
        }
        modeAnalyticsEvents = loadedEvents
    }

    private static var appSupportDirectoryURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentCrew", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var pipelinesFileURL: URL {
        appSupportDirectoryURL.appendingPathComponent("pipelines.json")
    }

    private static var llmConfigFileURL: URL {
        appSupportDirectoryURL.appendingPathComponent("llm-config.json")
    }

    private static var executionNotificationSettingsFileURL: URL {
        appSupportDirectoryURL.appendingPathComponent("execution-notification-settings.json")
    }

    private static var modeAnalyticsLogFileURL: URL {
        appSupportDirectoryURL.appendingPathComponent("mode-analytics.jsonl")
    }

    private static let maxConcurrentPipelineRunsDefaultsKey = "agentcrew.maxConcurrentPipelineRuns"

    // MARK: - Editing / Run history helpers

    private func isPipelineEditable(at pipelineIndex: Int) -> Bool {
        !isPipelineExecuting(pipelines[pipelineIndex].id)
    }

    private func startRunRecord(
        for pipelineID: UUID,
        pipelineSnapshot: Pipeline? = nil,
        stageIDs: Set<UUID>? = nil,
        orchestrationMode: OrchestrationMode? = nil,
        agentRoundIndex: Int? = nil,
        agentStrategy: AgentRepairStrategy? = nil
    ) -> UUID? {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return nil }
        var runPipeline = pipelineSnapshot ?? pipelines[pipelineIndex]
        if let stageIDs {
            runPipeline.stages = runPipeline.stages.filter { stageIDs.contains($0.id) }
        }

        var run = PipelineRunRecord(pipeline: runPipeline, startedAt: Date())
        run.orchestrationMode = orchestrationMode
        run.agentRoundIndex = agentRoundIndex
        run.agentStrategy = agentStrategy
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

    private func runRecord(pipelineID: UUID, runID: UUID) -> PipelineRunRecord? {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return nil }
        return pipelines[pipelineIndex].runHistory.first(where: { $0.id == runID })
    }

    private func recordRunCoverageSnapshot(
        pipelineID: UUID,
        runID: UUID,
        coverageItems: [AgentCoverageItem]
    ) {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }),
              let runIndex = pipelines[pipelineIndex].runHistory.firstIndex(where: { $0.id == runID })
        else { return }
        pipelines[pipelineIndex].runHistory[runIndex].coverageSnapshot = coverageItems
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

    private func executeRetrySnapshot(
        _ retrySnapshot: Pipeline,
        for pipeline: Pipeline,
        rootPipelineID: UUID,
        resetStepIDs: Set<UUID>,
        cancelledMessage: String
    ) async {
        executionError = nil
        stepStatuses = latestKnownStepStatuses(for: pipeline)
        for stepID in resetStepIDs {
            stepStatuses[stepID] = .pending
        }
        for step in retrySnapshot.allSteps {
            stepOutputs[step.id] = nil
        }

        let control = ExecutionControl()
        executionControlByPipelineID[rootPipelineID] = control
        defer {
            executionControlByPipelineID.removeValue(forKey: rootPipelineID)
        }

        let runID = startRunRecord(
            for: rootPipelineID,
            pipelineSnapshot: retrySnapshot,
            orchestrationMode: .pipeline
        )
        let rootSessionID = runID ?? UUID()
        let ref = WeakVM(vm: self)

        do {
            _ = try await scheduler.executePipeline(
                retrySnapshot,
                sharedStateExecutionContext: SharedStateExecutionContext(
                    rootSessionID: rootSessionID,
                    roundIndex: 0,
                    orchestrationMode: .pipeline
                ),
                executionControl: control,
                onStepStatusChanged: { id, status in
                    Task { @MainActor in
                        ref.vm?.stepStatuses[id] = status
                        if let runID {
                            ref.vm?.recordStepStatus(
                                pipelineID: rootPipelineID,
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
                                pipelineID: rootPipelineID,
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
                    pipelineID: rootPipelineID,
                    runID: runID,
                    status: .completed,
                    errorMessage: nil,
                    finishedAt: Date()
                )
            }
        } catch {
            let runStatus: PipelineRunStatus
            let message: String
            if let schedulerError = error as? SchedulerError {
                switch schedulerError {
                case .cancelled:
                    message = cancelledMessage
                    runStatus = .cancelled
                default:
                    message = error.localizedDescription
                    runStatus = .failed
                }
            } else {
                message = error.localizedDescription
                runStatus = .failed
            }
            executionError = message
            if let runID {
                finalizeRunRecord(
                    pipelineID: rootPipelineID,
                    runID: runID,
                    status: runStatus,
                    errorMessage: message,
                    finishedAt: Date()
                )
            }
        }

        savePipelines()
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

    private func publishAgentSession(_ session: AgentSessionState) {
        activeAgentSession = session
        latestAgentSessionByPipeline[session.pipelineID] = session
    }

    private func executePipelineSnapshot(
        _ pipelineSnapshot: Pipeline,
        rootPipelineID: UUID,
        rootSessionID: UUID,
        control: ExecutionControl,
        roundIndex: Int? = nil,
        strategy: AgentRepairStrategy? = nil
    ) async -> SnapshotExecutionOutcome {
        for step in pipelineSnapshot.allSteps {
            stepStatuses[step.id] = .pending
            stepOutputs[step.id] = nil
        }

        let runID = startRunRecord(
            for: rootPipelineID,
            pipelineSnapshot: pipelineSnapshot,
            orchestrationMode: roundIndex == nil ? nil : .agent,
            agentRoundIndex: roundIndex,
            agentStrategy: strategy
        )
        let ref = WeakVM(vm: self)

        do {
            _ = try await scheduler.executePipeline(
                pipelineSnapshot,
                sharedStateExecutionContext: SharedStateExecutionContext(
                    rootSessionID: rootSessionID,
                    roundIndex: roundIndex ?? 0,
                    orchestrationMode: roundIndex == nil ? .pipeline : .agent
                ),
                executionControl: control,
                onStepStatusChanged: { id, status in
                    Task { @MainActor in
                        ref.vm?.stepStatuses[id] = status
                        if let runID {
                            ref.vm?.recordStepStatus(
                                pipelineID: rootPipelineID,
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
                                pipelineID: rootPipelineID,
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
                    pipelineID: rootPipelineID,
                    runID: runID,
                    status: .completed,
                    errorMessage: nil,
                    finishedAt: Date()
                )
            }
            return SnapshotExecutionOutcome(runID: runID, status: .completed, errorMessage: nil)
        } catch {
            let runStatus: PipelineRunStatus
            let message: String
            if let schedulerError = error as? SchedulerError {
                switch schedulerError {
                case .cancelled:
                    runStatus = .cancelled
                    message = "Agent round stopped by user."
                default:
                    runStatus = .failed
                    message = error.localizedDescription
                }
            } else {
                runStatus = .failed
                message = error.localizedDescription
            }

            if let runID {
                finalizeRunRecord(
                    pipelineID: rootPipelineID,
                    runID: runID,
                    status: runStatus,
                    errorMessage: message,
                    finishedAt: Date()
                )
            }
            return SnapshotExecutionOutcome(runID: runID, status: runStatus, errorMessage: message)
        }
    }

    private func updateCoverageContract(
        session: inout AgentSessionState,
        run: PipelineRunRecord,
        roundIndex: Int,
        strategy: AgentRepairStrategy,
        basePipeline: Pipeline
    ) {
        let baseStepIDs = Set(basePipeline.allSteps.map(\.id))
        let missingBaseSteps = run.stageRuns
            .flatMap(\.stepRuns)
            .filter { baseStepIDs.contains($0.stepID) && ($0.status == .failed || $0.status == .skipped) }

        for missingStep in missingBaseSteps {
            if let existingIndex = session.coverageItems.firstIndex(where: { $0.sourceStepID == missingStep.stepID }) {
                session.coverageItems[existingIndex].sourceStepName = missingStep.stepName
            } else {
                session.coverageItems.append(
                    AgentCoverageItem(
                        sourceStepID: missingStep.stepID,
                        sourceStepName: missingStep.stepName,
                        firstFailedRound: roundIndex
                    )
                )
            }
        }

        let completedStepIDs = Set(
            run.stageRuns
                .flatMap(\.stepRuns)
                .filter { $0.status == .completed }
                .map(\.stepID)
        )

        for index in session.coverageItems.indices where !session.coverageItems[index].isResolved {
            let sourceID = session.coverageItems[index].sourceStepID
            guard completedStepIDs.contains(sourceID) else { continue }
            session.coverageItems[index].recoveredRound = roundIndex
            session.coverageItems[index].recoveredByStrategy = strategy
            session.coverageItems[index].evidenceKind = .directReplay
            session.coverageItems[index].evidenceNote = "Replayed source step succeeded in round \(roundIndex)."
        }

        if strategy == .globalReplan,
           run.status == .completed,
           countFailedSteps(in: run) == 0 {
            for index in session.coverageItems.indices where !session.coverageItems[index].isResolved {
                session.coverageItems[index].recoveredRound = roundIndex
                session.coverageItems[index].recoveredByStrategy = strategy
                session.coverageItems[index].evidenceKind = .inferredGlobalReplan
                session.coverageItems[index].evidenceNote = "Inferred covered by successful global replan."
            }
        }
    }

    private func enforceCoverageContract(
        evaluation: AgentEvaluationResult,
        session: AgentSessionState,
        roundIndex: Int,
        maxRounds: Int
    ) -> AgentEvaluationResult {
        guard evaluation.decision == .finish else { return evaluation }
        let unresolved = session.unresolvedCoverageItems
        guard !unresolved.isEmpty else { return evaluation }

        let unresolvedNames = unresolved
            .prefix(3)
            .map(\.sourceStepName)
            .joined(separator: ", ")
        let gateSummary = "Round \(roundIndex) passed, but coverage contract is unresolved: \(unresolvedNames)."
        var gateReasons = evaluation.reasons
        gateReasons.append("All previously failed source steps must be recovered before finish.")

        if roundIndex < maxRounds {
            return AgentEvaluationResult(
                decision: .replan,
                summary: gateSummary,
                reasons: Array(gateReasons.prefix(3)),
                nextRoundStrategy: .globalReplan
            )
        }

        return AgentEvaluationResult(
            decision: .abort,
            summary: "Coverage contract failed at max rounds. Pending: \(unresolvedNames).",
            reasons: Array(gateReasons.prefix(3)),
            nextRoundStrategy: nil
        )
    }

    private func evaluateAgentDecision(
        latestRun: PipelineRunRecord?,
        pipelineID: UUID,
        roundIndex: Int,
        maxRounds: Int,
        fallbackError: String?,
        currentStrategy: AgentRepairStrategy,
        basePipeline: Pipeline
    ) -> AgentEvaluationResult {
        guard let latestRun else {
            let summary = fallbackError ?? "No run record available for evaluator."
            return AgentEvaluationResult(
                decision: .abort,
                summary: summary,
                reasons: [summary],
                nextRoundStrategy: nil
            )
        }

        if latestRun.status == .completed, countFailedSteps(in: latestRun) == 0 {
            return AgentEvaluationResult(
                decision: .finish,
                summary: "Round \(roundIndex) completed with all steps passing.",
                reasons: ["All stages are completed."],
                nextRoundStrategy: nil
            )
        }

        if latestRun.status == .cancelled || isPipelineStopRequested(pipelineID) {
            return AgentEvaluationResult(
                decision: .abort,
                summary: "Execution was cancelled.",
                reasons: ["User requested stop."],
                nextRoundStrategy: nil
            )
        }

        if runContainsHardRiskSignal(latestRun) {
            return AgentEvaluationResult(
                decision: .askHuman,
                summary: "High-risk operation detected. Manual confirmation is required before continuing.",
                reasons: ["Detected destructive or privileged operation keywords in run output."],
                nextRoundStrategy: nil
            )
        }

        let failedSteps = countFailedSteps(in: latestRun)
        var reasons: [String] = []
        if failedSteps > 0 {
            reasons.append("Round \(roundIndex) has \(failedSteps) failed step(s).")
        }
        if runContainsSeveritySignal(latestRun) {
            reasons.append("Round output contains high/critical risk signals.")
        }
        if let errorMessage = latestRun.errorMessage, !errorMessage.isEmpty {
            reasons.append(errorMessage)
        }
        if reasons.isEmpty, let fallbackError, !fallbackError.isEmpty {
            reasons.append(fallbackError)
        }

        if roundIndex < maxRounds {
            if currentStrategy == .originalPipeline,
               let failedStageName = retryableFailedStageName(from: latestRun, basePipeline: basePipeline) {
                var retryReasons = reasons
                retryReasons.append("Auto retry failed stage before global replan.")
                return AgentEvaluationResult(
                    decision: .continue,
                    summary: "Round \(roundIndex) failed at stage \"\(failedStageName)\". Retrying that stage in round \(roundIndex + 1).",
                    reasons: Array(retryReasons.prefix(3)),
                    nextRoundStrategy: .retryFailedStage
                )
            }

            if currentStrategy == .retryFailedStage,
               let failedStepName = patchableFailedStepName(from: latestRun, basePipeline: basePipeline) {
                var patchReasons = reasons
                patchReasons.append("Stage retry still failed. Insert local patch before rerun.")
                return AgentEvaluationResult(
                    decision: .continue,
                    summary: "Round \(roundIndex) still failed at step \"\(failedStepName)\". Inserting a local patch step for round \(roundIndex + 1).",
                    reasons: Array(patchReasons.prefix(3)),
                    nextRoundStrategy: .localPatchInsert
                )
            }

            return AgentEvaluationResult(
                decision: .replan,
                summary: "Evaluator requests replan for round \(roundIndex + 1).",
                reasons: Array(reasons.prefix(3)),
                nextRoundStrategy: .globalReplan
            )
        }

        let summary = "Evaluator aborts: reached max rounds (\(maxRounds))."
        return AgentEvaluationResult(
            decision: .abort,
            summary: summary,
            reasons: Array((reasons + [summary]).prefix(3)),
            nextRoundStrategy: nil
        )
    }

    private func buildAgentRound(
        strategy: AgentRepairStrategy,
        basePipeline: Pipeline,
        roundIndex: Int,
        previousRun: PipelineRunRecord?,
        previousError: String?,
        humanInstruction: String?
    ) -> PlannedAgentRound {
        switch strategy {
        case .originalPipeline:
            return PlannedAgentRound(
                pipeline: basePipeline,
                strategy: .originalPipeline,
                summary: roundIndex == 1
                    ? "Initial round executes the selected pipeline."
                    : "Re-running the original pipeline."
            )
        case .retryFailedStage:
            if let retryRound = buildRetryFailedStageRound(
                from: basePipeline,
                previousRun: previousRun,
                roundIndex: roundIndex
            ) {
                return retryRound
            }
            let fallback = buildAgentReplanPipeline(
                from: basePipeline,
                roundIndex: roundIndex,
                previousRun: previousRun,
                previousError: previousError,
                humanInstruction: humanInstruction
            )
            return PlannedAgentRound(
                pipeline: fallback,
                strategy: .globalReplan,
                summary: "Failed stage context is unavailable. Falling back to global replan."
            )
        case .localPatchInsert:
            if let patchRound = buildLocalPatchRound(
                from: basePipeline,
                previousRun: previousRun,
                roundIndex: roundIndex,
                previousError: previousError,
                humanInstruction: humanInstruction
            ) {
                return patchRound
            }
            let fallback = buildAgentReplanPipeline(
                from: basePipeline,
                roundIndex: roundIndex,
                previousRun: previousRun,
                previousError: previousError,
                humanInstruction: humanInstruction
            )
            return PlannedAgentRound(
                pipeline: fallback,
                strategy: .globalReplan,
                summary: "Local patch context is unavailable. Falling back to global replan."
            )
        case .globalReplan:
            let pipeline = buildAgentReplanPipeline(
                from: basePipeline,
                roundIndex: roundIndex,
                previousRun: previousRun,
                previousError: previousError,
                humanInstruction: humanInstruction
            )
            let hasHumanInstruction = !(humanInstruction?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
            return PlannedAgentRound(
                pipeline: pipeline,
                strategy: .globalReplan,
                summary: hasHumanInstruction
                    ? "Round generated with human instruction override."
                    : "Auto-generated fix/review/verify round."
            )
        }
    }

    private func buildRetryFailedStageRound(
        from basePipeline: Pipeline,
        previousRun: PipelineRunRecord?,
        roundIndex: Int
    ) -> PlannedAgentRound? {
        guard let previousRun else { return nil }
        guard let failedStageRun = previousRun.stageRuns.first(where: { $0.status == .failed }) else { return nil }
        guard let stageIndex = basePipeline.stages.firstIndex(where: { $0.id == failedStageRun.stageID }) else { return nil }

        let sourceStage = basePipeline.stages[stageIndex]
        guard !sourceStage.steps.isEmpty else { return nil }
        let sourceStepIDs = Set(sourceStage.steps.map(\.id))

        // Retry only unresolved steps from the failed round.
        // Completed steps are treated as already satisfied and won't rerun.
        let unresolvedStepIDs = Set(
            failedStageRun.stepRuns
                .filter { ($0.status == .failed || $0.status == .skipped) && sourceStepIDs.contains($0.stepID) }
                .map(\.stepID)
        )
        guard !unresolvedStepIDs.isEmpty else { return nil }

        var retrySteps = sourceStage.steps.filter { unresolvedStepIDs.contains($0.id) }
        let retryStepIDs = Set(retrySteps.map(\.id))
        for stepIndex in retrySteps.indices {
            retrySteps[stepIndex].dependsOnStepIDs = retrySteps[stepIndex].dependsOnStepIDs.filter {
                retryStepIDs.contains($0)
            }
        }

        var retryStage = sourceStage
        retryStage.steps = retrySteps

        var retrySnapshot = basePipeline
        retrySnapshot.name = "\(basePipeline.name) · Agent Retry Round \(roundIndex)"
        retrySnapshot.stages = [retryStage]

        return PlannedAgentRound(
            pipeline: retrySnapshot,
            strategy: .retryFailedStage,
            summary: "Retrying unresolved steps in stage: \(retryStage.name)"
        )
    }

    private func buildLocalPatchRound(
        from basePipeline: Pipeline,
        previousRun: PipelineRunRecord?,
        roundIndex: Int,
        previousError: String?,
        humanInstruction: String?
    ) -> PlannedAgentRound? {
        guard let previousRun else { return nil }
        guard let failedStageRun = previousRun.stageRuns.first(where: { $0.status == .failed }) else { return nil }
        guard let failedStepRun = failedStageRun.stepRuns.first(where: { $0.status == .failed }) else { return nil }
        guard let stageIndex = basePipeline.stages.firstIndex(where: { $0.id == failedStageRun.stageID }) else { return nil }

        let sourceStage = basePipeline.stages[stageIndex]
        guard let failedStepIndex = sourceStage.steps.firstIndex(where: { $0.id == failedStepRun.stepID }) else { return nil }
        let failedStep = sourceStage.steps[failedStepIndex]
        let issueSummary = buildIssueSummary(
            from: previousRun,
            basePipeline: basePipeline,
            fallbackError: previousError
        )
        let instructionText = humanInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let humanInstructionSection = instructionText.isEmpty
            ? ""
            : """

            Human approval note:
            \(instructionText)
            """

        let patchStep = PipelineStep(
            name: "Patch for \(failedStep.name)",
            prompt: """
            The step "\(failedStep.name)" in stage "\(sourceStage.name)" failed in the previous round.
            Create a focused patch that addresses the failure before we rerun the failed step and its downstream steps.

            Failure summary:
            \(issueSummary)
            \(humanInstructionSection)

            Requirements:
            1) Keep the patch focused on unblocking "\(failedStep.name)".
            2) Preserve existing behavior outside this failure path.
            3) End with changed files and rationale.
            """,
            tool: .codex
        )

        var rerunSteps = Array(sourceStage.steps.suffix(from: failedStepIndex))
        let rerunStepIDs = Set(rerunSteps.map(\.id))
        for stepIndex in rerunSteps.indices {
            rerunSteps[stepIndex].dependsOnStepIDs = rerunSteps[stepIndex].dependsOnStepIDs.filter {
                rerunStepIDs.contains($0)
            }
        }

        if !rerunSteps.isEmpty {
            rerunSteps[0].dependsOnStepIDs = Array(Set(rerunSteps[0].dependsOnStepIDs + [patchStep.id]))
        }

        let patchStage = PipelineStage(
            id: sourceStage.id,
            name: sourceStage.name,
            steps: [patchStep] + rerunSteps,
            executionMode: .sequential
        )

        var patchSnapshot = basePipeline
        patchSnapshot.name = "\(basePipeline.name) · Agent Local Patch Round \(roundIndex)"
        patchSnapshot.stages = [patchStage]

        return PlannedAgentRound(
            pipeline: patchSnapshot,
            strategy: .localPatchInsert,
            summary: "Inserting local patch before rerunning failed step: \(failedStep.name)"
        )
    }

    private func retryableFailedStageName(from run: PipelineRunRecord, basePipeline: Pipeline) -> String? {
        guard let failedStageRun = run.stageRuns.first(where: { $0.status == .failed }) else { return nil }
        guard basePipeline.stages.contains(where: { $0.id == failedStageRun.stageID }) else { return nil }
        return failedStageRun.stageName
    }

    private func patchableFailedStepName(from run: PipelineRunRecord, basePipeline: Pipeline) -> String? {
        guard let failedStageRun = run.stageRuns.first(where: { $0.status == .failed }) else { return nil }
        guard let failedStepRun = failedStageRun.stepRuns.first(where: { $0.status == .failed }) else { return nil }
        guard let stage = basePipeline.stages.first(where: { $0.id == failedStageRun.stageID }) else { return nil }
        guard stage.steps.contains(where: { $0.id == failedStepRun.stepID }) else { return nil }
        return failedStepRun.stepName
    }

    private func buildAgentReplanPipeline(
        from basePipeline: Pipeline,
        roundIndex: Int,
        previousRun: PipelineRunRecord?,
        previousError: String?,
        humanInstruction: String?
    ) -> Pipeline {
        let issueSummary = buildIssueSummary(
            from: previousRun,
            basePipeline: basePipeline,
            fallbackError: previousError
        )
        let instructionText = humanInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let humanInstructionSection = instructionText.isEmpty
            ? ""
            : """

            Human approval note:
            \(instructionText)
            """

        let fixer = PipelineStep(
            name: "Fix round \(roundIndex) issues",
            prompt: """
            Previous round for "\(basePipeline.name)" failed.
            Fix all identified issues in the repository.

            Failure summary:
            \(issueSummary)
            \(humanInstructionSection)

            Requirements:
            1) Modify files directly to resolve root causes.
            2) Keep changes scoped to the original goal.
            3) End with a concise list of changed files and why.
            """,
            tool: .codex
        )

        let reviewer = PipelineStep(
            name: "Review fixes",
            prompt: """
            Review the new changes from the fixer step.
            Focus on correctness, security, and regressions.

            Context:
            \(issueSummary)
            \(humanInstructionSection)

            Mark any remaining high-risk findings explicitly.
            """,
            tool: .cursor
        )

        let verifier = PipelineStep(
            name: "Verify and patch",
            prompt: """
            Run relevant build/tests for "\(basePipeline.name)" and patch failures.

            Context:
            \(issueSummary)
            \(humanInstructionSection)

            Report pass/fail status and any remaining blockers.
            """,
            tool: .codex
        )

        let stage = PipelineStage(
            name: "Agent Round \(roundIndex): Fix + Review + Verify",
            steps: [fixer, reviewer, verifier],
            executionMode: .sequential
        )

        return Pipeline(
            name: "\(basePipeline.name) · Agent Round \(roundIndex)",
            stages: [stage],
            workingDirectory: basePipeline.workingDirectory,
            isAIGenerated: true
        )
    }

    private func buildIssueSummary(
        from run: PipelineRunRecord?,
        basePipeline: Pipeline?,
        fallbackError: String?
    ) -> String {
        var sections: [String] = []

        if let run {
            let allStepRuns = run.stageRuns.flatMap(\.stepRuns)
            let failedSteps = allStepRuns.filter { $0.status == .failed }
            let failedStepNames = failedSteps.map(\.stepName)
            let stepRunByID = Dictionary(uniqueKeysWithValues: allStepRuns.map { ($0.stepID, $0) })
            let dependencyMap = issueDependencyMap(for: basePipeline)

            if !failedSteps.isEmpty {
                sections.append("Failed steps (\(failedSteps.count)): \(failedStepNames.joined(separator: ", "))")

                for failedStep in failedSteps.prefix(maxIssueFailedStepsInSummary) {
                    var blockLines: [String] = []
                    blockLines.append("- Step: \(failedStep.stepName)")

                    let excerpt = issueExcerpt(from: failedStep.output, maxChars: maxIssueStepExcerptLength)
                    if !excerpt.isEmpty {
                        blockLines.append("  Output excerpt: \(excerpt)")
                    }

                    let dependencyStepIDs = dependencyMap[failedStep.stepID] ?? []
                    if !dependencyStepIDs.isEmpty {
                        let dependencyLines = dependencyStepIDs
                            .prefix(maxIssueDependenciesPerStep)
                            .compactMap { dependencyID -> String? in
                                guard let dependencyRun = stepRunByID[dependencyID] else { return nil }
                                let dependencyExcerpt = issueExcerpt(
                                    from: dependencyRun.output,
                                    maxChars: maxIssueDependencyExcerptLength
                                )
                                if dependencyExcerpt.isEmpty {
                                    return "\(dependencyRun.stepName) (status: \(dependencyRun.status.rawValue))"
                                }
                                return "\(dependencyRun.stepName): \(dependencyExcerpt)"
                            }

                        if !dependencyLines.isEmpty {
                            blockLines.append("  Dependency context:")
                            for dependencyLine in dependencyLines {
                                blockLines.append("    - \(dependencyLine)")
                            }
                        }
                    }

                    sections.append(blockLines.joined(separator: "\n"))
                }
            }

            if let errorMessage = run.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !errorMessage.isEmpty {
                sections.append("Run error: \(errorMessage)")
            }
        }

        if let fallbackError = fallbackError?.trimmingCharacters(in: .whitespacesAndNewlines), !fallbackError.isEmpty {
            sections.append("Fallback error: \(fallbackError)")
        }

        if sections.isEmpty {
            sections.append("No detailed failure context is available.")
        }

        let summary = sections.joined(separator: "\n\n")
        return trimmedIssueSummary(summary)
    }

    private func issueDependencyMap(for pipeline: Pipeline?) -> [UUID: [UUID]] {
        guard let pipeline else { return [:] }
        let resolvedSteps = pipeline.allStepsWithResolvedDependencies()
        let orderByStepID = Dictionary(uniqueKeysWithValues: pipeline.allSteps.enumerated().map { ($1.id, $0) })

        return Dictionary(uniqueKeysWithValues: resolvedSteps.map { resolved in
            let orderedDeps = resolved.allDependencies.sorted { lhs, rhs in
                let lhsOrder = orderByStepID[lhs] ?? .max
                let rhsOrder = orderByStepID[rhs] ?? .max
                return lhsOrder < rhsOrder
            }
            return (resolved.step.id, orderedDeps)
        })
    }

    private func issueExcerpt(from raw: String?, maxChars: Int) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }

        let compact = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard compact.count > maxChars else { return compact }
        let tail = String(compact.suffix(maxChars))
        return "...\(tail)"
    }

    private func trimmedIssueSummary(_ summary: String) -> String {
        guard summary.count > maxIssueSummaryLength else { return summary }
        let tail = String(summary.suffix(maxIssueSummaryLength))
        return """
        ...issue summary truncated...
        \(tail)
        """
    }

    private func containsAnyKeyword(in text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private func hasClosedLoopPattern(in text: String) -> Bool {
        let hasImplement = containsAnyKeyword(
            in: text,
            keywords: ["implement", "build", "code", "开发", "实现"]
        )
        let hasReview = containsAnyKeyword(
            in: text,
            keywords: ["review", "audit", "审查", "reviewer"]
        )
        let hasFixOrVerify = containsAnyKeyword(
            in: text,
            keywords: ["fix", "verify", "test", "修复", "验证", "回归"]
        )
        return hasImplement && hasReview && hasFixOrVerify
    }

    private func recentFailureRate(for pipeline: Pipeline, limit: Int) -> Double {
        let recentRuns = pipeline.runHistory
            .sorted(by: { $0.startedAt > $1.startedAt })
            .prefix(limit)
        guard !recentRuns.isEmpty else { return 0 }
        let failedCount = recentRuns.filter { $0.status == .failed }.count
        return Double(failedCount) / Double(recentRuns.count)
    }

    private func consecutiveSuccessCount(for pipeline: Pipeline) -> Int {
        let sortedRuns = pipeline.runHistory.sorted(by: { $0.startedAt > $1.startedAt })
        var count = 0
        for run in sortedRuns {
            guard run.status == .completed else { break }
            count += 1
        }
        return count
    }

    private func countFailedSteps(in run: PipelineRunRecord) -> Int {
        run.stageRuns.flatMap(\.stepRuns).filter { $0.status == .failed }.count
    }

    private func runContainsSeveritySignal(_ run: PipelineRunRecord) -> Bool {
        let text = runCombinedText(run)
        return containsAnyKeyword(
            in: text,
            keywords: ["high", "critical", "security", "vulnerability", "token", "auth", "高危", "严重"]
        )
    }

    private func runContainsHardRiskSignal(_ run: PipelineRunRecord) -> Bool {
        let text = runCombinedText(run)
        return containsAnyKeyword(
            in: text,
            keywords: ["drop table", "truncate table", "rm -rf", "delete from", "force push", "privilege escalation", "删除生产", "高危删除"]
        )
    }

    private func recentRunsFailingSameStage(in pipeline: Pipeline, minOccurrences: Int) -> Bool {
        let recentFailedRuns = pipeline.runHistory
            .sorted(by: { $0.startedAt > $1.startedAt })
            .filter { $0.status == .failed }
            .prefix(4)

        var failCountsByStage: [UUID: Int] = [:]
        for run in recentFailedRuns {
            guard let failedStage = run.stageRuns.first(where: { $0.status == .failed }) else { continue }
            failCountsByStage[failedStage.stageID, default: 0] += 1
            if failCountsByStage[failedStage.stageID, default: 0] >= minOccurrences {
                return true
            }
        }
        return false
    }

    private func runCombinedText(_ run: PipelineRunRecord) -> String {
        let outputText = run.stageRuns
            .flatMap(\.stepRuns)
            .compactMap(\.output)
            .joined(separator: " ")
        let errorText = run.errorMessage ?? ""
        return "\(outputText)\n\(errorText)".lowercased()
    }

    private func pipelineRunStatus(from sessionStatus: AgentSessionStatus) -> PipelineRunStatus? {
        switch sessionStatus {
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .created, .planning, .executing, .evaluating, .waitingHuman:
            return nil
        }
    }

    private func postExecutionCompletionNotificationIfNeeded(
        pipelineID: UUID,
        pipelineName: String,
        mode: OrchestrationMode,
        status: PipelineRunStatus,
        dedupID: UUID?,
        startedAt: Date,
        finishedAt: Date,
        errorMessage: String?
    ) async {
        guard executionNotificationSettings.isEnabled else { return }
        guard shouldSendExecutionNotification(for: status) else { return }

        let authorizationState = await notificationService.authorizationState()
        executionNotificationAuthorizationState = authorizationState
        guard authorizationState == .authorized else { return }

        let dedupKey = buildExecutionNotificationDedupKey(
            pipelineID: pipelineID,
            mode: mode,
            status: status,
            dedupID: dedupID,
            finishedAt: finishedAt
        )
        guard registerExecutionNotificationKey(dedupKey) else { return }

        do {
            try await notificationService.sendLocalNotification(
                identifier: "agentcrew-run-\(UUID().uuidString)",
                title: executionNotificationTitle(status: status, pipelineName: pipelineName),
                body: executionNotificationBody(
                    mode: mode,
                    status: status,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    errorMessage: errorMessage
                ),
                playSound: executionNotificationSettings.playSound
            )
        } catch {
            unregisterExecutionNotificationKey(dedupKey)
        }
    }

    private func shouldSendExecutionNotification(for status: PipelineRunStatus) -> Bool {
        switch status {
        case .completed:
            return executionNotificationSettings.notifyOnCompleted
        case .failed:
            return executionNotificationSettings.notifyOnFailed
        case .cancelled:
            return executionNotificationSettings.notifyOnCancelled
        case .running:
            return false
        }
    }

    private func executionNotificationTitle(status: PipelineRunStatus, pipelineName: String) -> String {
        switch status {
        case .completed:
            return "Pipeline completed: \(pipelineName)"
        case .failed:
            return "Pipeline failed: \(pipelineName)"
        case .cancelled:
            return "Pipeline cancelled: \(pipelineName)"
        case .running:
            return "Pipeline running: \(pipelineName)"
        }
    }

    private func executionNotificationBody(
        mode: OrchestrationMode,
        status: PipelineRunStatus,
        startedAt: Date,
        finishedAt: Date,
        errorMessage: String?
    ) -> String {
        var segments: [String] = [
            "Mode: \(mode.title)",
            "Status: \(status.rawValue.capitalized)"
        ]

        if let duration = formattedExecutionDuration(startedAt: startedAt, finishedAt: finishedAt) {
            segments.append("Duration: \(duration)")
        }

        if status != .completed,
           let trimmedError = truncatedNotificationErrorMessage(errorMessage) {
            segments.append("Reason: \(trimmedError)")
        }

        return segments.joined(separator: " | ")
    }

    private func formattedExecutionDuration(startedAt: Date, finishedAt: Date) -> String? {
        let duration = max(0, finishedAt.timeIntervalSince(startedAt))
        guard duration > 0 else { return nil }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration)
    }

    private func truncatedNotificationErrorMessage(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !compact.isEmpty else { return nil }
        if compact.count <= 140 {
            return compact
        }
        return String(compact.prefix(140)) + "..."
    }

    private func buildExecutionNotificationDedupKey(
        pipelineID: UUID,
        mode: OrchestrationMode,
        status: PipelineRunStatus,
        dedupID: UUID?,
        finishedAt: Date
    ) -> String {
        let base = dedupID?.uuidString
            ?? "\(pipelineID.uuidString)-\(Int(finishedAt.timeIntervalSince1970))"
        return "\(base)|\(mode.rawValue)|\(status.rawValue)"
    }

    private func registerExecutionNotificationKey(_ key: String) -> Bool {
        guard !deliveredExecutionNotificationKeySet.contains(key) else { return false }
        deliveredExecutionNotificationKeySet.insert(key)
        deliveredExecutionNotificationKeys.append(key)

        if deliveredExecutionNotificationKeys.count > maxDeliveredExecutionNotificationKeys {
            let overflow = deliveredExecutionNotificationKeys.count - maxDeliveredExecutionNotificationKeys
            let expiredKeys = deliveredExecutionNotificationKeys.prefix(overflow)
            deliveredExecutionNotificationKeys.removeFirst(overflow)
            for expiredKey in expiredKeys {
                deliveredExecutionNotificationKeySet.remove(expiredKey)
            }
        }
        return true
    }

    private func unregisterExecutionNotificationKey(_ key: String) {
        deliveredExecutionNotificationKeySet.remove(key)
        deliveredExecutionNotificationKeys.removeAll { $0 == key }
    }

    private func isRecommendationAcceptedEvent(_ event: ModeAnalyticsEvent) -> Bool {
        guard event.type == .modeRecommendationAccepted else { return false }
        let source = event.payload["source"] ?? ""
        return source == "pre_run_recommendation" || source == "runtime_suggestion"
    }

    private func preRunRecommendedMode(from event: ModeAnalyticsEvent) -> OrchestrationMode? {
        guard event.type == .modeRecommendationShown else { return nil }
        guard event.payload["source"] == "pre_run" else { return nil }
        guard let rawMode = event.payload["recommendedMode"] else { return nil }
        return OrchestrationMode(rawValue: rawMode)
    }

    private func firstPreRunRecommendationByPipeline() -> [UUID: (mode: OrchestrationMode, timestamp: Date)] {
        var firstByPipeline: [UUID: (mode: OrchestrationMode, timestamp: Date)] = [:]

        for event in modeAnalyticsEvents {
            guard let recommendedMode = preRunRecommendedMode(from: event) else { continue }
            if let existing = firstByPipeline[event.pipelineID],
               existing.timestamp <= event.timestamp {
                continue
            }
            firstByPipeline[event.pipelineID] = (
                mode: recommendedMode,
                timestamp: event.timestamp
            )
        }

        return firstByPipeline
    }

    private func buildModeRecommendationPipelineSummary() -> ModeRecommendationPipelineSummary {
        let firstRecommendationByPipeline = firstPreRunRecommendationByPipeline()
        let currentModeByPipeline = Dictionary(
            uniqueKeysWithValues: pipelines.map { ($0.id, $0.preferredRunMode) }
        )

        var recommendedAgentCount = 0
        var recommendedPipelineCount = 0
        var comparedPipelineCount = 0
        var matchedPipelineCount = 0
        var currentAgentCount = 0
        var currentPipelineCount = 0

        for (pipelineID, recommendation) in firstRecommendationByPipeline {
            switch recommendation.mode {
            case .agent:
                recommendedAgentCount += 1
            case .pipeline:
                recommendedPipelineCount += 1
            }

            guard let currentMode = currentModeByPipeline[pipelineID] else { continue }
            comparedPipelineCount += 1
            if currentMode == .agent {
                currentAgentCount += 1
            } else {
                currentPipelineCount += 1
            }
            if currentMode == recommendation.mode {
                matchedPipelineCount += 1
            }
        }

        return ModeRecommendationPipelineSummary(
            recommendedAgentCount: recommendedAgentCount,
            recommendedPipelineCount: recommendedPipelineCount,
            comparedPipelineCount: comparedPipelineCount,
            matchedPipelineCount: matchedPipelineCount,
            currentAgentCount: currentAgentCount,
            currentPipelineCount: currentPipelineCount
        )
    }

    private func buildModeRecommendationDailyTrend(days: Int) -> [ModeRecommendationDailyPoint] {
        guard days > 0 else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var agentByDay: [Date: Int] = [:]
        var pipelineByDay: [Date: Int] = [:]
        for recommendation in firstPreRunRecommendationByPipeline().values {
            let day = calendar.startOfDay(for: recommendation.timestamp)
            switch recommendation.mode {
            case .agent:
                agentByDay[day, default: 0] += 1
            case .pipeline:
                pipelineByDay[day, default: 0] += 1
            }
        }

        var points: [ModeRecommendationDailyPoint] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            points.append(
                ModeRecommendationDailyPoint(
                    dayStart: day,
                    recommendedAgentCount: agentByDay[day, default: 0],
                    recommendedPipelineCount: pipelineByDay[day, default: 0]
                )
            )
        }
        return points
    }

    private func buildModeRecommendationPipelineRows() -> [ModeRecommendationPipelineRow] {
        let recommendationByPipeline = firstPreRunRecommendationByPipeline()
        let pipelineByID = Dictionary(uniqueKeysWithValues: pipelines.map { ($0.id, $0) })

        return recommendationByPipeline
            .map { pipelineID, recommendation in
                let pipeline = pipelineByID[pipelineID]
                let latestRun = pipeline?.runHistory.max { lhs, rhs in
                    let lhsDate = lhs.endedAt ?? lhs.startedAt
                    let rhsDate = rhs.endedAt ?? rhs.startedAt
                    return lhsDate < rhsDate
                }
                let totalRunDuration: TimeInterval? = {
                    guard let pipeline else { return nil }
                    guard !pipeline.runHistory.isEmpty else { return nil }

                    let now = Date()
                    return pipeline.runHistory.reduce(0) { partial, run in
                        let endTime = run.endedAt ?? (run.status == .running ? now : nil)
                        guard let endTime else { return partial }
                        return partial + max(0, endTime.timeIntervalSince(run.startedAt))
                    }
                }()

                return ModeRecommendationPipelineRow(
                    pipelineID: pipelineID,
                    pipelineName: pipeline?.name ?? "Deleted Pipeline",
                    workingDirectory: pipeline?.workingDirectory ?? "",
                    recommendedMode: recommendation.mode,
                    currentMode: pipeline?.preferredRunMode,
                    firstRecommendedAt: recommendation.timestamp,
                    latestRunStatus: latestRun?.status,
                    latestRunFinishedAt: latestRun?.endedAt ?? latestRun?.startedAt,
                    totalRunDuration: totalRunDuration
                )
            }
            .sorted { $0.firstRecommendedAt > $1.firstRecommendedAt }
    }

    private func buildModeAnalyticsDailyTrend(days: Int) -> [ModeAnalyticsDailyPoint] {
        guard days > 0 else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var shownByDay: [Date: Int] = [:]
        var acceptedByDay: [Date: Int] = [:]
        var dismissedByDay: [Date: Int] = [:]
        var runtimeSwitchByDay: [Date: Int] = [:]

        for event in modeAnalyticsEvents {
            let day = calendar.startOfDay(for: event.timestamp)
            switch event.type {
            case .modeRecommendationShown:
                shownByDay[day, default: 0] += 1
            case .modeRecommendationAccepted:
                if isRecommendationAcceptedEvent(event) {
                    acceptedByDay[day, default: 0] += 1
                }
            case .modeRecommendationDismissed:
                dismissedByDay[day, default: 0] += 1
            case .modeSwitchedRuntime:
                runtimeSwitchByDay[day, default: 0] += 1
            case .taskOutcomeByMode:
                break
            }
        }

        var points: [ModeAnalyticsDailyPoint] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            points.append(
                ModeAnalyticsDailyPoint(
                    dayStart: day,
                    shownCount: shownByDay[day, default: 0],
                    acceptedCount: acceptedByDay[day, default: 0],
                    dismissedCount: dismissedByDay[day, default: 0],
                    runtimeSwitchCount: runtimeSwitchByDay[day, default: 0]
                )
            )
        }
        return points
    }

    private func analyticsSourceName(_ source: ModeSwitchSource) -> String {
        switch source {
        case .manual:
            return "manual"
        case .preRunRecommendation:
            return "pre_run_recommendation"
        case .runtimeSuggestion:
            return "runtime_suggestion"
        }
    }

    private func trackModeAnalyticsEvent(
        _ type: ModeAnalyticsEventType,
        pipelineID: UUID,
        payload: [String: String] = [:]
    ) {
        let event = ModeAnalyticsEvent(
            type: type,
            pipelineID: pipelineID,
            payload: payload
        )
        modeAnalyticsEvents.append(event)
        if modeAnalyticsEvents.count > maxModeAnalyticsEvents {
            modeAnalyticsEvents.removeFirst(modeAnalyticsEvents.count - maxModeAnalyticsEvents)
        }
        appendModeAnalyticsEventLine(event)
    }

    private func appendModeAnalyticsEventLine(_ event: ModeAnalyticsEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(event) else { return }

        var lineData = data
        lineData.append(0x0A)

        let fileManager = FileManager.default
        let fileURL = Self.modeAnalyticsLogFileURL

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: lineData)
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(lineData)
        } catch {
            fileManager.createFile(atPath: fileURL.path, contents: lineData)
        }
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
