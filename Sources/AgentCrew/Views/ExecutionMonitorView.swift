import SwiftUI

struct ExecutionMonitorView: View {
    private enum MonitorTab: String, CaseIterable, Identifiable {
        case running = "Running Record"
        case history = "History"
        var id: Self { self }
    }

    private let outputPreviewCharacterLimit = 8_000
    private let outputViewportHeight: CGFloat = 220

    let pipeline: Pipeline
    @EnvironmentObject var vm: AppViewModel
    @State private var selectedTab: MonitorTab = .history
    @State private var expandedStageRunIDs: Set<UUID> = []
    @State private var fullOutputStepRunIDs: Set<UUID> = []

    private var isPipelineExecuting: Bool {
        vm.isPipelineExecuting(pipeline.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            tabPicker
            Divider()
            contentArea
        }
        .background(.background)
        .onAppear {
            selectedTab = isPipelineExecuting ? .running : .history
        }
        .onChange(of: pipeline.runHistory.count) {
            if isPipelineExecuting {
                selectedTab = .running
            }
        }
        .onChange(of: vm.executingPipelineID) { _, executingPipelineID in
            if executingPipelineID == pipeline.id {
                selectedTab = .running
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            if isPipelineExecuting {
                ProgressView()
                    .controlSize(.small)
                Text("Executing…")
                    .font(.caption.bold())
            } else if let latestRunRecord {
                Image(systemName: runStatusIcon(latestRunRecord.status))
                    .foregroundStyle(runStatusColor(latestRunRecord.status))
                if latestRunRecord.status == .failed || latestRunRecord.status == .cancelled,
                   let error = latestRunRecord.errorMessage,
                   !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(runStatusColor(latestRunRecord.status))
                        .lineLimit(1)
                } else {
                    Text(latestRunRecord.status.rawValue.capitalized)
                        .font(.caption.bold())
                        .foregroundStyle(runStatusColor(latestRunRecord.status))
                }
            } else {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text("Run Monitor").font(.caption.bold())
            }
            Spacer()
            statusSummary
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var tabPicker: some View {
        Picker("Monitor View", selection: $selectedTab) {
            ForEach(MonitorTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var contentArea: some View {
        switch selectedTab {
        case .running:
            runningArea
        case .history:
            historyArea
        }
    }

    private var statusSummary: some View {
        HStack(spacing: 8) {
            ForEach([StepStatus.completed, .running, .failed, .skipped], id: \.self) { status in
                let count = statusCounts[status, default: 0]
                if count > 0 {
                    HStack(spacing: 2) {
                        Circle().fill(color(for: status)).frame(width: 6, height: 6)
                        Text("\(count)").font(.caption2)
                    }
                }
            }
        }
    }

    private var statusCounts: [StepStatus: Int] {
        var counts: [StepStatus: Int] = [:]

        if isPipelineExecuting {
            let stepIDs = Set(pipeline.allSteps.map(\.id))
            for (stepID, status) in vm.stepStatuses where stepIDs.contains(stepID) {
                counts[status, default: 0] += 1
            }
            return counts
        }

        guard let latestRunRecord else { return counts }
        for status in latestRunRecord.stageRuns
            .flatMap(\.stepRuns)
            .map(\.status) {
            counts[status, default: 0] += 1
        }
        return counts
    }

    // MARK: - Run history

    private var runningArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let latestRunRecord {
                        runCard(latestRunRecord) { stageRunID in
                            collapseStageAndKeepVisible(stageRunID, proxy: proxy)
                        }
                    } else {
                        emptyStateView(
                            title: "No run yet",
                            systemImage: "play.circle",
                            message: "Run this pipeline to keep the latest execution record here."
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    private var historyArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if recentHistoryRecords.isEmpty {
                        emptyStateView(
                            title: "No run history",
                            systemImage: "clock.arrow.circlepath",
                            message: "Run this pipeline to see stage duration, progress, and status history."
                        )
                    } else {
                        ForEach(recentHistoryRecords) { run in
                            runCard(run) { stageRunID in
                                collapseStageAndKeepVisible(stageRunID, proxy: proxy)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var sortedRunHistory: [PipelineRunRecord] {
        pipeline.runHistory.sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }
    }

    private var latestRunRecord: PipelineRunRecord? {
        sortedRunHistory.first
    }

    private var recentHistoryRecords: [PipelineRunRecord] {
        Array(sortedRunHistory.prefix(3))
    }

    private func runCard(
        _ run: PipelineRunRecord,
        onCollapseFromBottom: @escaping (UUID) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: runStatusIcon(run.status))
                    .foregroundStyle(runStatusColor(run.status))
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.bold())
                Spacer()
                Text(run.status.rawValue.capitalized)
                    .font(.caption2.bold())
                    .foregroundStyle(runStatusColor(run.status))
                if let duration = run.duration {
                    Text(durationText(duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Text("Stages:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(run.completedStages)/\(run.stageRuns.count) completed")
                    .font(.caption2.bold())
                Spacer()
                Text("Click progress to expand output")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(run.stageRuns) { stage in
                stageRow(stage, onCollapseFromBottom: onCollapseFromBottom)
            }

            if let error = run.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stageRow(
        _ stage: StageRunRecord,
        onCollapseFromBottom: @escaping (UUID) -> Void
    ) -> some View {
        let isExpanded = expandedStageRunIDs.contains(stage.id)

        return VStack(alignment: .leading, spacing: 4) {
            Button {
                toggleStageExpansion(stage.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: stage.status))
                            .frame(width: 8, height: 8)
                        Text(stage.stageName)
                            .font(.caption.bold())
                        Spacer()
                        Text(stage.status.rawValue.capitalized)
                            .font(.caption2)
                            .foregroundStyle(color(for: stage.status))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: stage.progress)
                        .controlSize(.small)

                    HStack(spacing: 10) {
                        Text("\(stage.finishedSteps)/\(stage.totalSteps) done")
                        if stage.failedSteps > 0 { Text("failed \(stage.failedSteps)") }
                        if stage.skippedSteps > 0 { Text("skipped \(stage.skippedSteps)") }
                        if let startedAt = stage.startedAt, let endedAt = stage.endedAt {
                            Text("\(startedAt.formatted(date: .omitted, time: .shortened))-\(endedAt.formatted(date: .omitted, time: .shortened))")
                        } else if let startedAt = stage.startedAt {
                            Text("started \(startedAt.formatted(date: .omitted, time: .shortened))")
                        }
                        if let duration = stage.duration {
                            Text(durationText(duration))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                stageOutputDetails(stage, onCollapseFromBottom: onCollapseFromBottom)
            }
        }
        .id(stage.id)
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func stageOutputDetails(
        _ stage: StageRunRecord,
        onCollapseFromBottom: @escaping (UUID) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(stage.stepRuns) { stepRun in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(stepRun.stepName)
                            .font(.caption.bold())
                        Spacer()
                        Text(stepRun.status.rawValue.capitalized)
                            .font(.caption2)
                            .foregroundStyle(color(for: stepRun.status))
                    }

                    if let output = stepRun.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                        let showFullOutput = fullOutputStepRunIDs.contains(stepRun.id)
                        let needsTruncation = output.count > outputPreviewCharacterLimit
                        let previewOutput = String(output.suffix(outputPreviewCharacterLimit))
                        let renderedOutput = showFullOutput || !needsTruncation
                            ? output
                            : """
                            ...showing latest \(outputPreviewCharacterLimit) characters...

                            \(previewOutput)
                            """

                        ScrollView {
                            Text(renderedOutput)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: outputViewportHeight)
                        .padding(6)
                        .background(.background.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary, lineWidth: 1)
                        )

                        if needsTruncation {
                            HStack {
                                Spacer()
                                Button(showFullOutput ? "Show less" : "Show full output") {
                                    toggleFullOutput(for: stepRun.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    } else if stepRun.status == .running {
                        Text("Running... waiting for tool output.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No output captured.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button {
                    onCollapseFromBottom(stage.id)
                } label: {
                    Label("Collapse", systemImage: "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private func color(for status: StepStatus) -> Color {
        switch status {
        case .pending:   .secondary
        case .running:   .blue
        case .completed: .green
        case .failed:    .red
        case .skipped:   .orange
        }
    }

    private func runStatusColor(_ status: PipelineRunStatus) -> Color {
        switch status {
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }

    private func runStatusIcon(_ status: PipelineRunStatus) -> String {
        switch status {
        case .running: "clock.badge.checkmark"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration) ?? "\(Int(duration))s"
    }

    private func toggleStageExpansion(_ stageRunID: UUID) {
        if expandedStageRunIDs.contains(stageRunID) {
            expandedStageRunIDs.remove(stageRunID)
        } else {
            expandedStageRunIDs.insert(stageRunID)
        }
    }

    private func toggleFullOutput(for stepRunID: UUID) {
        if fullOutputStepRunIDs.contains(stepRunID) {
            fullOutputStepRunIDs.remove(stepRunID)
        } else {
            fullOutputStepRunIDs.insert(stepRunID)
        }
    }

    private func collapseStageAndKeepVisible(_ stageRunID: UUID, proxy: ScrollViewProxy) {
        expandedStageRunIDs.remove(stageRunID)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(stageRunID, anchor: .top)
            }
        }
    }

    private func emptyStateView(title: String, systemImage: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.bold())
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}
