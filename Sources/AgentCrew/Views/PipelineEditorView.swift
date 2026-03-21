import SwiftUI

struct PipelineEditorView: View {
    let pipeline: Pipeline
    @EnvironmentObject var vm: AppViewModel
    @State private var newStageName = ""
    @State private var newStageMode: ExecutionMode = .parallel
    @State private var showAddStage = false
    @State private var showEditPipeline = false
    @State private var humanApprovalInstruction = ""
    private var isPipelineExecuting: Bool {
        vm.isPipelineExecuting(pipeline.id)
    }
    private var isPipelineQueued: Bool {
        vm.isPipelineQueued(pipeline.id)
    }
    private var isAgentExecuting: Bool {
        vm.isAgentExecuting(pipeline.id)
    }

    private var latestRunRecord: PipelineRunRecord? {
        pipeline.runHistory.sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }.first
    }

    private var latestFailedStageRun: StageRunRecord? {
        guard let latestRunRecord, latestRunRecord.status == .failed else { return nil }
        return latestRunRecord.stageRuns.first(where: { $0.status == .failed })
    }

    private var canRetryLatestFailedStage: Bool {
        guard let stageID = latestFailedStageRun?.stageID else { return false }
        return pipeline.stages.contains(where: { $0.id == stageID })
    }

    private var selectedRunMode: OrchestrationMode {
        vm.preferredRunMode(for: pipeline.id)
    }

    private var selectedRunModeBinding: Binding<OrchestrationMode> {
        Binding(
            get: { vm.preferredRunMode(for: pipeline.id) },
            set: { vm.setPreferredRunMode($0, for: pipeline.id) }
        )
    }

    private var recommendation: ModeRecommendation {
        vm.modeRecommendation(for: pipeline)
    }

    private var canSwitchRunMode: Bool {
        !isPipelineExecuting && !isPipelineQueued
    }

    var body: some View {
        VStack(spacing: 0) {
            pipelineHeader
            Divider()

            if pipeline.stages.isEmpty {
                emptyState
            } else {
                VSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(pipeline.stages) { stage in
                                StageCard(
                                    stage: stage,
                                    pipelineID: pipeline.id,
                                    isEditingLocked: isPipelineExecuting,
                                    isPipelineExecuting: isPipelineExecuting,
                                    isAgentExecuting: isAgentExecuting
                                )
                            }

                            addStageButton
                        }
                        .padding()
                    }
                    .frame(minHeight: 220)

                    ExecutionMonitorView(pipeline: pipeline)
                        .frame(minHeight: 220, idealHeight: 360)
                }
            }
        }
        .navigationTitle(pipeline.name)
        .sheet(isPresented: $showAddStage) { addStageSheet }
        .sheet(isPresented: $showEditPipeline) { EditPipelineSheet(pipeline: pipeline) }
    }

    // MARK: - Header

    private var pipelineHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                pipelineInfo
                Spacer()

                if isPipelineExecuting || isPipelineQueued {
                    HStack(spacing: 6) {
                        if isPipelineExecuting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(
                            isPipelineExecuting
                                ? (isAgentExecuting ? L10n.text("pipeline.agentRunning", fallback: "Agent running...") : L10n.text("status.running", fallback: "Running..."))
                                : L10n.text("status.queued", fallback: "Queued...")
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if isPipelineExecuting {
                    Button {
                        vm.stopPipeline(pipeline.id)
                    } label: {
                        Label(
                            vm.isPipelineStopRequested(pipeline.id)
                                ? L10n.text("common.stopping", fallback: "Stopping...")
                                : (isAgentExecuting ? L10n.text("pipeline.stopAgent", fallback: "Stop Agent") : L10n.text("pipeline.stopPipeline", fallback: "Stop Pipeline")),
                            systemImage: "stop.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(vm.isPipelineStopRequested(pipeline.id))
                }

                Button {
                    vm.showFlowchart = true
                } label: {
                    Label(L10n.text("flowchart.titleShort", fallback: "Flowchart"), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(pipeline.allSteps.isEmpty)
                .help(L10n.text("flowchart.showHelp", fallback: "Show execution flowchart (wave-based DAG)"))

                Button {
                    showEditPipeline = true
                } label: {
                    Label(L10n.text("common.edit", fallback: "Edit"), systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .disabled(isPipelineExecuting)
                .help(editPipelineHelpText)

                Button {
                    Task { await vm.executeSelectedMode(for: pipeline) }
                } label: {
                    Label(
                        selectedRunMode == .agent ? L10n.text("pipeline.runAgent", fallback: "Run Agent") : L10n.text("pipeline.runPipeline", fallback: "Run Pipeline"),
                        systemImage: selectedRunMode == .agent ? "sparkles" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedRunMode == .agent ? .purple : .green)
                .disabled(isPipelineExecuting || isPipelineQueued || pipeline.allSteps.isEmpty)
                .help(
                    isPipelineQueued
                        ? (vm.queuedReason(for: pipeline.id) ?? L10n.text("pipeline.waitingInQueue", fallback: "This pipeline is waiting in queue."))
                        : (
                            selectedRunMode == .agent
                                ? L10n.text("pipeline.runAsAgentHelp", fallback: "Run as adaptive multi-round Agent session.")
                                : L10n.text("pipeline.runAsPipelineHelp", fallback: "Run as deterministic Pipeline DAG.")
                        )
                )
            }

            modeSelectionPanel

            if isPipelineQueued, let reason = vm.queuedReason(for: pipeline.id) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if !isPipelineExecuting && !isPipelineQueued,
               let suggestion = vm.runtimeSwitchSuggestion(for: pipeline) {
                runtimeSwitchBanner(suggestion)
            }

            if let session = vm.latestAgentSession(for: pipeline.id) {
                agentSessionBanner(session)
            }

            if let failedStage = latestFailedStageRun, !isPipelineExecuting, canRetryLatestFailedStage {
                latestFailureBanner(failedStage)
            }
        }
        .padding()
    }

    private var pipelineInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pipeline.name).font(.headline)
            if !pipeline.workingDirectory.isEmpty {
                Text(pipeline.workingDirectory)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(L10n.text("project.noWorkingDirectory", fallback: "No working directory set"))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !isPipelineExecuting else { return }
            showEditPipeline = true
        }
        .help(editPipelineHelpText)
    }

    private var modeSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(L10n.text("pipeline.runMode", fallback: "Run Mode"))
                    .font(.caption.bold())

                Picker(L10n.text("pipeline.runMode", fallback: "Run Mode"), selection: selectedRunModeBinding) {
                    ForEach(OrchestrationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(!canSwitchRunMode)
                .help(canSwitchRunMode ? L10n.text("pipeline.chooseModeForNextRun", fallback: "Choose the mode used for the next run.") : L10n.text("pipeline.stopBeforeSwitchingMode", fallback: "Stop current run before switching mode."))

                Text("\(L10n.text("common.recommended", fallback: "Recommended")): \(recommendation.recommendedMode.title)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(recommendationColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(recommendationColor)

                Spacer()

                Text("\(L10n.text("common.score", fallback: "Score")) \(recommendation.score)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if selectedRunMode != recommendation.recommendedMode {
                    Button(L10n.text("common.useRecommended", fallback: "Use Recommended")) {
                        vm.setPreferredRunMode(
                            recommendation.recommendedMode,
                            for: pipeline.id,
                            source: .preRunRecommendation
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!canSwitchRunMode)
                }
            }

            if !recommendation.reasons.isEmpty {
                Text(recommendation.reasons.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .task(id: recommendationTrackingKey) {
            vm.applyInitialAgentRecommendationIfNeeded(
                for: pipeline.id,
                recommendation: recommendation
            )
            vm.markPreRunRecommendationShown(
                for: pipeline.id,
                recommendation: recommendation
            )
        }
    }

    private func runtimeSwitchBanner(_ suggestion: RuntimeModeSuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(L10n.text("common.suggestion", fallback: "Suggestion")): \(L10n.text("pipeline.switchTo", fallback: "switch to")) \(suggestion.suggestedMode.title)")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text(suggestion.reasons.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button(L10n.text("pipeline.switchToAgent", fallback: "Switch to Agent")) {
                vm.acceptRuntimeSwitchSuggestion(for: pipeline.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(L10n.text("common.dismiss", fallback: "Dismiss")) {
                vm.dismissRuntimeModeSuggestion(for: pipeline.id)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            vm.markRuntimeSuggestionShown(for: pipeline.id, suggestion: suggestion)
        }
    }

    private func agentSessionBanner(_ session: AgentSessionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: agentStatusIcon(session.status))
                    .foregroundStyle(agentStatusColor(session.status))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(L10n.text("agent.session", fallback: "Agent session")): \(session.status.localizedTitle)")
                        .font(.caption.bold())
                        .foregroundStyle(agentStatusColor(session.status))
                    Text("\(L10n.text("agent.round", fallback: "Round")) \(session.currentRound)/\(session.maxRounds)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if session.coverageRequiredCount > 0 {
                        Text("\(L10n.text("agent.coverage", fallback: "Coverage")): \(session.coverageResolvedCount)/\(session.coverageRequiredCount) \(L10n.text("agent.resolved", fallback: "resolved"))")
                            .font(.caption2)
                            .foregroundStyle(session.unresolvedCoverageItems.isEmpty ? .green : .orange)
                    }
                    if let latestRound = session.rounds.last {
                        if let strategy = latestRound.strategy {
                            Text("\(L10n.text("agent.strategy", fallback: "Strategy")): \(strategy.displayName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if strategy == .retryFailedStage {
                                Text(L10n.text("agent.onlyUnresolvedRetried", fallback: "Only unresolved steps are retried."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(latestRound.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let failureMessage = session.failureMessage, !failureMessage.isEmpty {
                        Text(failureMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()
            }

            if session.status == .waitingHuman {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        L10n.text("agent.optionalInstruction", fallback: "Optional instruction for next round (e.g. keep API stable, avoid schema change)"),
                        text: $humanApprovalInstruction
                    )
                    .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button(L10n.text("agent.approveAndContinue", fallback: "Approve and Continue")) {
                            let instruction = humanApprovalInstruction
                            humanApprovalInstruction = ""
                            Task {
                                await vm.resumeAgentSessionAfterHumanApproval(
                                    for: pipeline,
                                    instruction: instruction
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                        .disabled(vm.isPipelineExecuting(pipeline.id) || vm.isPipelineQueued(pipeline.id))

                        Button(L10n.text("agent.abortSession", fallback: "Abort Session")) {
                            humanApprovalInstruction = ""
                            vm.abortWaitingAgentSession(for: pipeline.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                        .disabled(vm.isPipelineExecuting(pipeline.id))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(agentStatusColor(session.status).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var recommendationColor: Color {
        switch recommendation.recommendedMode {
        case .pipeline:
            return .blue
        case .agent:
            return recommendation.strength == .weak ? .orange : .purple
        }
    }

    private var recommendationTrackingKey: String {
        "\(recommendation.recommendedMode.rawValue)|\(recommendation.score)|\(recommendation.reasons.joined(separator: "||"))"
    }

    private func agentStatusColor(_ status: AgentSessionStatus) -> Color {
        switch status {
        case .created, .planning, .executing, .evaluating:
            return .blue
        case .waitingHuman:
            return .orange
        case .completed:
            return .green
        case .failed, .cancelled:
            return .red
        }
    }

    private func agentStatusIcon(_ status: AgentSessionStatus) -> String {
        switch status {
        case .created, .planning:
            return "sparkles"
        case .executing:
            return "play.circle.fill"
        case .evaluating:
            return "checkmark.seal"
        case .waitingHuman:
            return "hand.raised.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "stop.circle.fill"
        }
    }

    private func latestFailureBanner(_ failedStage: StageRunRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(L10n.text("pipeline.latestRunFailedAtStage", fallback: "Latest run failed at stage")): \(failedStage.stageName)")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                if let errorMessage = latestRunRecord?.errorMessage,
                   !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task { await vm.retryStage(failedStage.stageID, in: pipeline.id) }
            } label: {
                Label(L10n.text("pipeline.retryFailedStage", fallback: "Retry Failed Stage"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(vm.isPipelineExecuting(pipeline.id) || vm.isPipelineQueued(pipeline.id))
            .help(
                vm.isPipelineQueued(pipeline.id)
                    ? L10n.text("pipeline.alreadyQueued", fallback: "This pipeline is already queued.")
                    : (vm.isPipelineExecuting(pipeline.id) ? L10n.text("pipeline.currentlyRunning", fallback: "This pipeline is currently running.") : L10n.text("pipeline.retryFailedStageOnly", fallback: "Retry this failed stage only."))
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 8) {
                Text(L10n.text("pipeline.buildYourPipeline", fallback: "Build Your Pipeline"))
                    .font(.title2.bold())

                Text(L10n.text("pipeline.buildYourPipelineDescription", fallback: "A pipeline has **Stages**, each containing **Steps**.\nStages run top-to-bottom. Steps within a stage run\neither in parallel or sequentially."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: 24) {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Text(L10n.text("mode.parallel", fallback: "Parallel"))
                        .font(.caption.bold())
                    Text(L10n.text("pipeline.parallelDescription", fallback: "All steps run\nat the same time"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 120)
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

                VStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text(L10n.text("mode.sequential", fallback: "Sequential"))
                        .font(.caption.bold())
                    Text(L10n.text("pipeline.sequentialDescription", fallback: "Steps run one\nafter another"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 120)
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(spacing: 10) {
                Button(L10n.text("pipeline.loadDemoTemplate", fallback: "Load Demo Template"), systemImage: "doc.badge.plus") {
                    vm.loadDemoTemplate(into: pipeline.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(L10n.text("pipeline.addEmptyStage", fallback: "Add Empty Stage")) {
                    showAddStage = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Inline add stage

    private var addStageButton: some View {
        Button {
            showAddStage = true
        } label: {
            HStack {
                Image(systemName: "plus.rectangle")
                Text(L10n.text("pipeline.addAnotherStage", fallback: "Add Another Stage"))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isPipelineExecuting)
    }

    // MARK: - Add Stage Sheet

    private var addStageSheet: some View {
        VStack(spacing: 16) {
            Text(L10n.text("pipeline.addStage", fallback: "Add Stage")).font(.title3.bold())

            TextField(L10n.text("pipeline.stageNamePlaceholder", fallback: "Stage Name (e.g. Coding, Review)"), text: $newStageName)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("execution.mode", fallback: "Execution Mode")).font(.subheadline.bold())
                Picker(L10n.text("execution.mode", fallback: "Execution Mode"), selection: $newStageMode) {
                    Label(L10n.text("mode.parallel", fallback: "Parallel"), systemImage: "arrow.triangle.branch").tag(ExecutionMode.parallel)
                    Label(L10n.text("mode.sequential", fallback: "Sequential"), systemImage: "arrow.down").tag(ExecutionMode.sequential)
                }
                .pickerStyle(.segmented)
                Text(newStageMode == .parallel
                     ? L10n.text("pipeline.parallelStageHelp", fallback: "All steps in this stage will run at the same time.")
                     : L10n.text("pipeline.sequentialStageHelp", fallback: "Steps will run one after another, in order.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button(L10n.text("common.cancel", fallback: "Cancel")) { showAddStage = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("pipeline.addStage", fallback: "Add Stage")) {
                    vm.addStage(to: pipeline.id, name: newStageName.isEmpty ? "\(L10n.text("common.stage", fallback: "Stage")) \(pipeline.stages.count + 1)" : newStageName, mode: newStageMode)
                    newStageName = ""
                    showAddStage = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isPipelineExecuting)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var editPipelineHelpText: String {
        if isPipelineExecuting {
            return L10n.text("pipeline.stopBeforeEditing", fallback: "Stop this pipeline run before editing pipeline settings.")
        }
        return L10n.text("pipeline.editNameAndDirectory", fallback: "Edit pipeline name and project directory.")
    }
}

// MARK: - Edit Pipeline Sheet

struct EditPipelineSheet: View {
    let pipeline: Pipeline
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var name: String
    @State private var workingDirectory: String
    @State private var lastSuggestedName: String

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
        _name = State(initialValue: pipeline.name)
        _workingDirectory = State(initialValue: pipeline.workingDirectory)
        _lastSuggestedName = State(initialValue: pipeline.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("pipeline.edit", fallback: "Edit Pipeline")).font(.title2.bold())

            GroupBox(L10n.text("common.project", fallback: "Project")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(L10n.text("project.selectFolder", fallback: "Select project folder"), text: $workingDirectory)
                            .textFieldStyle(.roundedBorder)
                            .disabled(vm.isPipelineExecuting(pipeline.id))
                            .onChange(of: workingDirectory) { _, newValue in
                                syncNameWithWorkingDirectory(newValue, force: false)
                            }
                        Button(L10n.text("common.browse", fallback: "Browse")) { browseFolder() }
                            .disabled(vm.isPipelineExecuting(pipeline.id))
                    }
                    Text(L10n.text("project.allStepsRunInsideDirectory", fallback: "All steps in this pipeline will run inside this project directory."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            TextField(L10n.text("pipeline.name", fallback: "Pipeline Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isPipelineExecuting(pipeline.id))

            if vm.isPipelineExecuting(pipeline.id) {
                Label(L10n.text("pipeline.stopBeforeEditingNameOrDirectory", fallback: "Stop the current run before editing the pipeline name or project directory."), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(L10n.text("common.cancel", fallback: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("common.save", fallback: "Save")) {
                    vm.updatePipeline(
                        pipeline.id,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    vm.isPipelineExecuting(pipeline.id)
                    || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
            syncNameWithWorkingDirectory(url.path, force: true)
        }
    }

    private func syncNameWithWorkingDirectory(_ workingDirectory: String, force: Bool) {
        guard let suggestedName = Pipeline.suggestedName(forWorkingDirectory: workingDirectory) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || trimmedName.isEmpty || trimmedName == lastSuggestedName {
            name = suggestedName
        }
        lastSuggestedName = suggestedName
    }
}

// MARK: - StageCard

private struct StageCard: View {
    let stage: PipelineStage
    let pipelineID: UUID
    let isEditingLocked: Bool
    let isPipelineExecuting: Bool
    let isAgentExecuting: Bool
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if stage.steps.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Text(L10n.text("pipeline.noStepsYet", fallback: "No steps yet"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(L10n.text("pipeline.addStepConfigureCommand", fallback: "Add a step and configure the command to run."))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                ForEach(stage.steps) { step in
                    StepRow(
                        step: step,
                        pipelineID: pipelineID,
                        isEditingLocked: isEditingLocked,
                        isPipelineExecuting: isPipelineExecuting
                    )
                }

                Button {
                    let stepNumber = stage.steps.count + 1
                    let step = PipelineStep(
                        name: "\(L10n.text("common.step", fallback: "Step")) \(stepNumber)",
                        prompt: ""
                    )
                    vm.addStep(to: stage.id, in: pipelineID, step: step)
                    vm.selectedStepID = step.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text(L10n.text("pipeline.addStep", fallback: "Add Step"))
                    }
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
                .disabled(isEditingLocked)
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Image(systemName: stage.executionMode == .parallel ? "arrow.triangle.branch" : "arrow.down")
                    .foregroundStyle(stage.executionMode == .parallel ? .blue : .orange)
                Text(stage.name)
                    .font(.subheadline.bold())
                Spacer()

                if let latestStatus = latestKnownStageStatus {
                    Text("\(L10n.text("common.latest", fallback: "Latest")) \(latestStatus.localizedTitle)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stageStatusColor(latestStatus).opacity(0.16), in: Capsule())
                        .foregroundStyle(stageStatusColor(latestStatus))
                }

                Text(stage.executionMode.localizedTitle)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        (stage.executionMode == .parallel ? Color.blue : Color.orange).opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(stage.executionMode == .parallel ? .blue : .orange)

                Text("\(stage.steps.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                if !isPipelineExecuting && !isAgentExecuting && !vm.isPipelineQueued(pipelineID) && canRetryStage {
                    Button {
                        Task { await vm.retryStage(stage.id, in: pipelineID) }
                    } label: {
                        Label(L10n.text("common.retry", fallback: "Retry"), systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.isPipelineExecuting(pipelineID) || vm.isPipelineQueued(pipelineID))
                    .help(stageRetryHelpText)
                }

                Button(role: .destructive) {
                    vm.deleteStage(stage.id, from: pipelineID)
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isEditingLocked)

                if isPipelineExecuting && !isAgentExecuting {
                    Button {
                        vm.stopStage(stage.id, in: pipelineID)
                    } label: {
                        Image(systemName: isStoppingStage ? "stop.circle.fill" : "stop.circle")
                            .font(.caption)
                            .foregroundStyle(isStoppingStage ? .orange : .red)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canStopStage || isStoppingStage || vm.isPipelineStopRequested(pipelineID))
                    .help(stageStopHelpText)
                }
            }
        }
    }

    private var canStopStage: Bool {
        guard isPipelineExecuting, !isAgentExecuting else { return false }
        return stage.steps.contains { step in
            let status = vm.stepStatuses[step.id] ?? .pending
            return status == .pending || status == .running
        }
    }

    private var latestKnownStageStatus: StepStatus? {
        vm.latestStageStatus(pipelineID: pipelineID, stageID: stage.id)
    }

    private var canRetryStage: Bool {
        guard !stage.steps.isEmpty else { return false }
        guard let status = latestKnownStageStatus else { return false }
        return status == .failed
    }

    private var isStoppingStage: Bool {
        vm.isStageStopRequested(stage.id, in: pipelineID)
    }

    private var stageStopHelpText: String {
        guard isPipelineExecuting else { return L10n.text("pipeline.notRunning", fallback: "This pipeline is not running.") }
        if isAgentExecuting {
            return L10n.text("pipeline.stageStopUnavailableAgent", fallback: "Stage-level stop is unavailable in Agent mode.")
        }
        if vm.isPipelineStopRequested(pipelineID) {
            return L10n.text("pipeline.stopRequested", fallback: "Pipeline stop has been requested.")
        }
        if isStoppingStage {
            return L10n.text("pipeline.stoppingStage", fallback: "Stopping this stage...")
        }
        if canStopStage {
            return L10n.text("pipeline.stopStageHelp", fallback: "Stop running and pending steps in this stage.")
        }
        return L10n.text("pipeline.stageAlreadyFinished", fallback: "This stage has already finished.")
    }

    private var stageRetryHelpText: String {
        if vm.isPipelineQueued(pipelineID) {
            return L10n.text("pipeline.alreadyQueued", fallback: "This pipeline is already queued.")
        }
        if vm.isPipelineExecuting(pipelineID) {
            return L10n.text("pipeline.currentlyRunning", fallback: "This pipeline is currently running.")
        }
        return L10n.text("pipeline.retryFailedStageOnly", fallback: "Retry this failed stage only.")
    }

    private func stageStatusColor(_ status: StepStatus) -> Color {
        switch status {
        case .pending: .secondary
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .skipped: .orange
        }
    }
}

// MARK: - StepRow

private struct StepRow: View {
    let step: PipelineStep
    let pipelineID: UUID
    let isEditingLocked: Bool
    let isPipelineExecuting: Bool
    @EnvironmentObject var vm: AppViewModel

    private var isSelected: Bool { vm.selectedStepID == step.id }

    var body: some View {
        let tool = step.displayTool ?? step.tool

        HStack(spacing: 8) {
            Image(systemName: tool.iconName)
                .foregroundStyle(tool.tintColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(step.name).lineLimit(1)
                        .font(.callout)
                    Text(tool.displayName)
                        .font(.caption2.bold())
                        .foregroundStyle(tool.tintColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tool.tintColor.opacity(0.12), in: Capsule())
                    if let model = step.model, !model.isEmpty {
                        Text(model)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !step.prompt.isEmpty {
                    Text(String(step.prompt.prefix(60)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(L10n.text("pipeline.clickToSetPrompt", fallback: "Click to set prompt →"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            statusBadge

            if !isPipelineExecuting && !vm.isPipelineQueued(pipelineID) && canRetryStep {
                Button {
                    Task { await vm.retryStep(step.id, in: pipelineID) }
                } label: {
                    Label(L10n.text("common.retry", fallback: "Retry"), systemImage: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isPipelineExecuting(pipelineID) || vm.isPipelineQueued(pipelineID))
                .help(stepRetryHelpText)
            }

            Button(role: .destructive) {
                vm.deleteStep(step.id, from: pipelineID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isEditingLocked)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.selectedStepID = step.id }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let status = displayStatus
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            Text(status.localizedTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var latestKnownStatus: StepStatus? {
        vm.latestStepStatus(pipelineID: pipelineID, stepID: step.id)
    }

    private var displayStatus: StepStatus {
        isPipelineExecuting
            ? (vm.stepStatuses[step.id] ?? latestKnownStatus ?? step.status)
            : (latestKnownStatus ?? step.status)
    }

    private var canRetryStep: Bool {
        switch latestKnownStatus {
        case .failed, .skipped:
            return true
        default:
            return false
        }
    }

    private var stepRetryHelpText: String {
        if vm.isPipelineQueued(pipelineID) {
            return L10n.text("pipeline.alreadyQueued", fallback: "This pipeline is already queued.")
        }
        if vm.isPipelineExecuting(pipelineID) {
            return L10n.text("pipeline.currentlyRunning", fallback: "This pipeline is currently running.")
        }
        return L10n.text("pipeline.retryFailedOrSkippedStepOnly", fallback: "Retry this failed or skipped step only.")
    }

    private func statusColor(_ status: StepStatus) -> Color {
        switch status {
        case .pending:   .secondary
        case .running:   .blue
        case .completed: .green
        case .failed:    .red
        case .skipped:   .orange
        }
    }
}
