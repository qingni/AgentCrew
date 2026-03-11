import SwiftUI

struct PipelineEditorView: View {
    let pipeline: Pipeline
    @EnvironmentObject var vm: AppViewModel
    @State private var newStageName = ""
    @State private var newStageMode: ExecutionMode = .parallel
    @State private var showAddStage = false
    @State private var showEditPipeline = false

    private var isPipelineExecuting: Bool {
        vm.isPipelineExecuting(pipeline.id)
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

    var body: some View {
        VStack(spacing: 0) {
            pipelineHeader
            Divider()

            VSplitView {
                if pipeline.stages.isEmpty {
                    emptyState
                        .frame(minHeight: 220)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(pipeline.stages) { stage in
                                StageCard(
                                    stage: stage,
                                    pipelineID: pipeline.id,
                                    isPipelineLocked: pipeline.isLockedAfterRun,
                                    isPipelineExecuting: isPipelineExecuting
                                )
                            }

                            addStageButton
                        }
                        .padding()
                    }
                    .frame(minHeight: 220)
                }

                ExecutionMonitorView(pipeline: pipeline)
                    .frame(minHeight: 220, idealHeight: 360)
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

                if isPipelineExecuting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running...").font(.caption).foregroundStyle(.secondary)
                    }

                    Button {
                        vm.stopPipeline()
                    } label: {
                        Label(vm.isStopRequested ? "Stopping..." : "Stop Pipeline", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(vm.isStopRequested)
                }

                if pipeline.isLockedAfterRun {
                    Label("Locked after first run", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button {
                    showEditPipeline = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .disabled(isPipelineExecuting || pipeline.isLockedAfterRun)
                .help(editPipelineHelpText)

                Button {
                    Task { await vm.executePipeline(pipeline) }
                } label: {
                    Label("Run Pipeline", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(vm.isExecuting || pipeline.allSteps.isEmpty)
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
            guard !isPipelineExecuting && !pipeline.isLockedAfterRun else { return }
            showEditPipeline = true
        }
        .help(editPipelineHelpText)
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
            .disabled(vm.isExecuting)
            .help(vm.isExecuting ? "Another pipeline is currently running." : "Retry this failed stage only.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Build Your Pipeline")
                .font(.title3.bold())

            Text("A pipeline has **Stages**, each containing **Steps**.\nStages run top-to-bottom. Steps within a stage run either in parallel or sequentially.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 8) {
                Label("**Parallel stage**: all steps run at the same time", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                Label("**Sequential stage**: steps run one after another", systemImage: "arrow.down")
                    .font(.caption)
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Button("Load Demo Template", systemImage: "doc.badge.plus") {
                vm.loadDemoTemplate(into: pipeline.id)
            }
            .buttonStyle(.borderedProminent)

            Button("Add Empty Stage Instead") {
                showAddStage = true
            }
            .buttonStyle(.link)
        }
        .frame(maxHeight: .infinity)
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
        .disabled(isPipelineExecuting || pipeline.isLockedAfterRun)
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
                .disabled(isPipelineExecuting || pipeline.isLockedAfterRun)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var editPipelineHelpText: String {
        if isPipelineExecuting {
            return "Stop this pipeline run before editing pipeline settings."
        }
        if pipeline.isLockedAfterRun {
            return "This pipeline is locked after its first run."
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
                            .disabled(vm.isPipelineExecuting(pipeline.id) || pipeline.isLockedAfterRun)
                            .onChange(of: workingDirectory) { _, newValue in
                                syncNameWithWorkingDirectory(newValue, force: false)
                            }
                        Button("Browse") { browseFolder() }
                            .disabled(vm.isPipelineExecuting(pipeline.id) || pipeline.isLockedAfterRun)
                    }
                    Text("All steps in this pipeline will run inside this project directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            TextField("Pipeline Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isPipelineExecuting(pipeline.id) || pipeline.isLockedAfterRun)

            if vm.isPipelineExecuting(pipeline.id) {
                Label("Stop the current run before editing the pipeline name or project directory.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if pipeline.isLockedAfterRun {
                Label("This pipeline is locked after its first run.", systemImage: "lock.fill")
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
                    || pipeline.isLockedAfterRun
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
    let isPipelineLocked: Bool
    let isPipelineExecuting: Bool
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
                        isPipelineLocked: isPipelineLocked,
                        isPipelineExecuting: isPipelineExecuting
                    )
                }

                Button {
                    let stepNumber = stage.steps.count + 1
                    let step = PipelineStep(
                        name: "Step \(stepNumber)",
                        command: ToolType.codex.defaultCommandTemplate(),
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
                .disabled(isPipelineExecuting || isPipelineLocked)
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

                if !isPipelineExecuting && canRetryStage {
                    Button {
                        Task { await vm.retryStage(stage.id, in: pipelineID) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.isExecuting)
                    .help(stageRetryHelpText)
                }

                Button(role: .destructive) {
                    vm.deleteStage(stage.id, from: pipelineID)
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isPipelineExecuting || isPipelineLocked)

                if isPipelineExecuting {
                    Button {
                        vm.stopStage(stage.id, in: pipelineID)
                    } label: {
                        Image(systemName: isStoppingStage ? "stop.circle.fill" : "stop.circle")
                            .font(.caption)
                            .foregroundStyle(isStoppingStage ? .orange : .red)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canStopStage || isStoppingStage || vm.isStopRequested)
                    .help(stageStopHelpText)
                }
            }
        }
    }

    private var canStopStage: Bool {
        guard isPipelineExecuting else { return false }
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
        vm.isStageStopRequested(stage.id)
    }

    private var stageStopHelpText: String {
        guard isPipelineExecuting else { return "This pipeline is not running." }
        if vm.isStopRequested {
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
        if vm.isExecuting {
            return "Another pipeline is currently running."
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
    let isPipelineLocked: Bool
    let isPipelineExecuting: Bool
    @EnvironmentObject var vm: AppViewModel

    private var isSelected: Bool { vm.selectedStepID == step.id }

    var body: some View {
        let displayTool = step.displayTool

        HStack(spacing: 8) {
            Image(systemName: displayTool?.iconName ?? "terminal")
                .foregroundStyle(displayTool?.tintColor ?? .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.name).lineLimit(1)
                    .font(.callout)
                if let secondaryText = secondaryText {
                    Text(secondaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Click to set command or prompt \u{2192}")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            statusBadge

            Button(role: .destructive) {
                vm.deleteStep(step.id, from: pipelineID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isPipelineExecuting || isPipelineLocked)
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

    private var secondaryText: String? {
        if !step.prompt.isEmpty {
            return String(step.prompt.prefix(60))
        }
        if step.hasCustomCommand {
            return String(step.effectiveCommand.prefix(60))
        }
        return nil
    }

    @ViewBuilder
    private var statusBadge: some View {
        let latestKnownStatus = vm.latestStepStatus(pipelineID: pipelineID, stepID: step.id)
        let status = isPipelineExecuting
            ? (vm.stepStatuses[step.id] ?? latestKnownStatus ?? step.status)
            : (latestKnownStatus ?? step.status)
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            Text(status.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
