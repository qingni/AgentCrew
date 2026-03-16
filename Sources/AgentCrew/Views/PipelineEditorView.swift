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
                                ? (isAgentExecuting ? "Agent running..." : "Running...")
                                : "Queued..."
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
                                ? "Stopping..."
                                : (isAgentExecuting ? "Stop Agent" : "Stop Pipeline"),
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
                    Label("Flowchart", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(pipeline.allSteps.isEmpty)
                .help("Show execution flowchart (wave-based DAG)")

                Button {
                    showEditPipeline = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .disabled(isPipelineExecuting)
                .help(editPipelineHelpText)

                Button {
                    Task { await vm.executeSelectedMode(for: pipeline) }
                } label: {
                    Label(
                        selectedRunMode == .agent ? "Run Agent" : "Run Pipeline",
                        systemImage: selectedRunMode == .agent ? "sparkles" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedRunMode == .agent ? .purple : .green)
                .disabled(isPipelineExecuting || isPipelineQueued || pipeline.allSteps.isEmpty)
                .help(
                    isPipelineQueued
                        ? (vm.queuedReason(for: pipeline.id) ?? "This pipeline is waiting in queue.")
                        : (
                            selectedRunMode == .agent
                                ? "Run as adaptive multi-round Agent session."
                                : "Run as deterministic Pipeline DAG."
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
                Text("No working directory set")
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
                Text("Run Mode")
                    .font(.caption.bold())

                Picker("Run Mode", selection: selectedRunModeBinding) {
                    ForEach(OrchestrationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(!canSwitchRunMode)
                .help(canSwitchRunMode ? "Choose the mode used for the next run." : "Stop current run before switching mode.")

                Text("Recommended: \(recommendation.recommendedMode.title)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(recommendationColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(recommendationColor)

                Spacer()

                Text("Score \(recommendation.score)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if selectedRunMode != recommendation.recommendedMode {
                    Button("Use Recommended") {
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
                Text("Suggestion: switch to \(suggestion.suggestedMode.title)")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text(suggestion.reasons.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Switch to Agent") {
                vm.acceptRuntimeSwitchSuggestion(for: pipeline.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Dismiss") {
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
                    Text("Agent session: \(session.status.rawValue)")
                        .font(.caption.bold())
                        .foregroundStyle(agentStatusColor(session.status))
                    Text("Round \(session.currentRound)/\(session.maxRounds)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if session.coverageRequiredCount > 0 {
                        Text("Coverage: \(session.coverageResolvedCount)/\(session.coverageRequiredCount) resolved")
                            .font(.caption2)
                            .foregroundStyle(session.unresolvedCoverageItems.isEmpty ? .green : .orange)
                    }
                    if let latestRound = session.rounds.last {
                        if let strategy = latestRound.strategy {
                            Text("Strategy: \(strategy.displayName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if strategy == .retryFailedStage {
                                Text("Only unresolved steps are retried.")
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
                        "Optional instruction for next round (e.g. keep API stable, avoid schema change)",
                        text: $humanApprovalInstruction
                    )
                    .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("Approve and Continue") {
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

                        Button("Abort Session") {
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
                Text("Latest run failed at stage: \(failedStage.stageName)")
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
                Label("Retry Failed Stage", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(vm.isPipelineExecuting(pipeline.id) || vm.isPipelineQueued(pipeline.id))
            .help(
                vm.isPipelineQueued(pipeline.id)
                    ? "This pipeline is already queued."
                    : (vm.isPipelineExecuting(pipeline.id) ? "This pipeline is currently running." : "Retry this failed stage only.")
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
                Text("Build Your Pipeline")
                    .font(.title2.bold())

                Text("A pipeline has **Stages**, each containing **Steps**.\nStages run top-to-bottom. Steps within a stage run\neither in parallel or sequentially.")
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
                    Text("Parallel")
                        .font(.caption.bold())
                    Text("All steps run\nat the same time")
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
                    Text("Sequential")
                        .font(.caption.bold())
                    Text("Steps run one\nafter another")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 120)
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(spacing: 10) {
                Button("Load Demo Template", systemImage: "doc.badge.plus") {
                    vm.loadDemoTemplate(into: pipeline.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Add Empty Stage") {
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
                Text("Add Another Stage")
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
            Text("Add Stage").font(.title3.bold())

            TextField("Stage Name (e.g. Coding, Review)", text: $newStageName)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Execution Mode").font(.subheadline.bold())
                Picker("Execution Mode", selection: $newStageMode) {
                    Label("Parallel", systemImage: "arrow.triangle.branch").tag(ExecutionMode.parallel)
                    Label("Sequential", systemImage: "arrow.down").tag(ExecutionMode.sequential)
                }
                .pickerStyle(.segmented)
                Text(newStageMode == .parallel
                     ? "All steps in this stage will run at the same time."
                     : "Steps will run one after another, in order."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") { showAddStage = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Stage") {
                    vm.addStage(to: pipeline.id, name: newStageName.isEmpty ? "Stage \(pipeline.stages.count + 1)" : newStageName, mode: newStageMode)
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
            return "Stop this pipeline run before editing pipeline settings."
        }
        return "Edit pipeline name and project directory."
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
            Text("Edit Pipeline").font(.title2.bold())

            GroupBox("Project") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Select project folder", text: $workingDirectory)
                            .textFieldStyle(.roundedBorder)
                            .disabled(vm.isPipelineExecuting(pipeline.id))
                            .onChange(of: workingDirectory) { _, newValue in
                                syncNameWithWorkingDirectory(newValue, force: false)
                            }
                        Button("Browse") { browseFolder() }
                            .disabled(vm.isPipelineExecuting(pipeline.id))
                    }
                    Text("All steps in this pipeline will run inside this project directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            TextField("Pipeline Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isPipelineExecuting(pipeline.id))

            if vm.isPipelineExecuting(pipeline.id) {
                Label("Stop the current run before editing the pipeline name or project directory.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
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
                            Text("No steps yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Add a step and configure the command to run.")
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
                        name: "Step \(stepNumber)",
                        prompt: ""
                    )
                    vm.addStep(to: stage.id, in: pipelineID, step: step)
                    vm.selectedStepID = step.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Step")
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
                    Text("Latest \(latestStatus.rawValue.capitalized)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stageStatusColor(latestStatus).opacity(0.16), in: Capsule())
                        .foregroundStyle(stageStatusColor(latestStatus))
                }

                Text(stage.executionMode == .parallel ? "Parallel" : "Sequential")
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
                        Label("Retry", systemImage: "arrow.clockwise")
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
        guard isPipelineExecuting else { return "This pipeline is not running." }
        if isAgentExecuting {
            return "Stage-level stop is unavailable in Agent mode."
        }
        if vm.isPipelineStopRequested(pipelineID) {
            return "Pipeline stop has been requested."
        }
        if isStoppingStage {
            return "Stopping this stage..."
        }
        if canStopStage {
            return "Stop running and pending steps in this stage."
        }
        return "This stage has already finished."
    }

    private var stageRetryHelpText: String {
        if vm.isPipelineQueued(pipelineID) {
            return "This pipeline is already queued."
        }
        if vm.isPipelineExecuting(pipelineID) {
            return "This pipeline is currently running."
        }
        return "Retry this failed stage only."
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
                    Text("Click to set prompt \u{2192}")
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
                    Label("Retry", systemImage: "arrow.clockwise")
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
            Text(status.rawValue.capitalized)
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
            return "This pipeline is already queued."
        }
        if vm.isPipelineExecuting(pipelineID) {
            return "This pipeline is currently running."
        }
        return "Retry this failed or skipped step only."
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
