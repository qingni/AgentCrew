import SwiftUI
import AppKit

struct ModeAnalyticsView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var analyticsStatusMessage = ""
    @State private var analyticsStatusIsError = false
    private let recommendedColumnWidth: CGFloat = 110
    private let currentColumnWidth: CGFloat = 90
    private let matchColumnWidth: CGFloat = 80
    private let outcomeColumnWidth: CGFloat = 150
    private let durationColumnWidth: CGFloat = 110
    private let comparisonRowVerticalPadding: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Mode Insights") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        analyticsMetricCard(
                            title: "Recommended Agent",
                            value: "\(recommendationPipelineSummary.recommendedAgentCount)",
                            subtitle: "Unique pipelines (first pre-run recommendation)",
                            tint: .purple
                        )
                        analyticsMetricCard(
                            title: "Recommended Pipeline",
                            value: "\(recommendationPipelineSummary.recommendedPipelineCount)",
                            subtitle: "Unique pipelines (first pre-run recommendation)",
                            tint: .blue
                        )
                        analyticsMetricCard(
                            title: "Mode Match",
                            value: recommendationMatchRateText,
                            subtitle: "Current mode matches recommendation \(recommendationPipelineSummary.matchedPipelineCount) / \(recommendationPipelineSummary.comparedPipelineCount)",
                            tint: .green
                        )
                    }

                    Text(
                        "Current mode split: Agent \(recommendationPipelineSummary.currentAgentCount) / Pipeline \(recommendationPipelineSummary.currentPipelineCount) · Runtime switch \(vm.modeRuntimeSwitchCount) · Dismissed \(vm.modeRecommendationDismissedCount)"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("7-Day Trend (New Pipelines by Recommendation)")
                            .font(.caption2.bold())

                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(dailyTrendPoints) { point in
                                dailyTrendColumn(point)
                            }
                        }

                        HStack(spacing: 10) {
                            analyticsLegendDot(color: .purple, label: "Recommended Agent")
                            analyticsLegendDot(color: .blue, label: "Recommended Pipeline")
                        }
                    }

                    Text(analyticsSummaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text(vm.modeAnalyticsLogPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Button("Open in Finder") {
                            openModeAnalyticsLogInFinder()
                        }
                        .controlSize(.small)

                        Button("Export JSONL…") {
                            exportModeAnalyticsLog()
                        }
                        .controlSize(.small)

                        Button("Clear Log") {
                            clearModeAnalyticsLog()
                        }
                        .controlSize(.small)
                    }

                    if !analyticsStatusMessage.isEmpty {
                        Text(analyticsStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(analyticsStatusIsError ? .red : .secondary)
                    }
                }
                .padding(8)
            }

            GroupBox("Pipeline Comparison") {
                VStack(alignment: .leading, spacing: 8) {
                    if pipelineRows.isEmpty {
                        Text("No pre-run recommendation has been recorded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        pipelineComparisonHeader()
                        Divider()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(pipelineRows) { row in
                                    pipelineComparisonRow(row)
                                    if row.id != pipelineRows.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .navigationTitle("Mode Insights")
    }

    private var recommendationPipelineSummary: AppViewModel.ModeRecommendationPipelineSummary {
        vm.modeRecommendationPipelineSummary
    }

    private var recommendationMatchRateText: String {
        percentageText(recommendationPipelineSummary.matchRate)
    }

    private var pipelineRows: [AppViewModel.ModeRecommendationPipelineRow] {
        vm.modeRecommendationPipelineRows
    }

    private var analyticsSummaryText: String {
        if recommendationPipelineSummary.totalRecommendedCount == 0 {
            return "No pre-run recommendation has been recorded yet."
        }
        return "Unique pipelines \(recommendationPipelineSummary.totalRecommendedCount) · Recommended Agent \(recommendationPipelineSummary.recommendedAgentCount) / Pipeline \(recommendationPipelineSummary.recommendedPipelineCount) · Current mode match \(recommendationPipelineSummary.matchedPipelineCount) / \(recommendationPipelineSummary.comparedPipelineCount)"
    }

    private var dailyTrendPoints: [AppViewModel.ModeRecommendationDailyPoint] {
        vm.modeRecommendationDailyTrendLast7Days
    }

    private var maxDailyTrendValue: Int {
        max(
            1,
            dailyTrendPoints.map { max($0.recommendedAgentCount, $0.recommendedPipelineCount) }.max() ?? 1
        )
    }

    @ViewBuilder
    private func pipelineComparisonHeader() -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Pipeline")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Recommended")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: recommendedColumnWidth, alignment: .leading)
            Text("Current")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: currentColumnWidth, alignment: .leading)
            Text("Match")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: matchColumnWidth, alignment: .leading)
            Text("Latest Outcome")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: outcomeColumnWidth, alignment: .leading)
            Text("Total Duration")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: durationColumnWidth, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func pipelineComparisonRow(_ row: AppViewModel.ModeRecommendationPipelineRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.pipelineName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !row.workingDirectory.isEmpty {
                    Text(row.workingDirectory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("First recommendation · \(shortDateTime(row.firstRecommendedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            modeChip(for: row.recommendedMode)
                .frame(width: recommendedColumnWidth, alignment: .leading)

            modeChip(for: row.currentMode, fallback: "Deleted")
                .frame(width: currentColumnWidth, alignment: .leading)

            matchChip(for: row.isMatched)
                .frame(width: matchColumnWidth, alignment: .leading)

            Text(latestOutcomeText(status: row.latestRunStatus, finishedAt: row.latestRunFinishedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: outcomeColumnWidth, alignment: .leading)

            Text(totalDurationText(row.totalRunDuration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: durationColumnWidth, alignment: .leading)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, comparisonRowVerticalPadding)
    }

    private func modeChip(for mode: OrchestrationMode?, fallback: String = "Unknown") -> some View {
        let text: String
        let color: Color
        if let mode {
            text = mode.title
            color = mode == .agent ? .purple : .blue
        } else {
            text = fallback
            color = .secondary
        }
        return Text(text)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func matchChip(for matched: Bool?) -> some View {
        let text: String
        let color: Color
        switch matched {
        case .some(true):
            text = "Matched"
            color = .green
        case .some(false):
            text = "Different"
            color = .orange
        case .none:
            text = "N/A"
            color = .secondary
        }
        return Text(text)
            .font(.caption.bold())
            .foregroundStyle(color)
    }

    private func latestOutcomeText(status: PipelineRunStatus?, finishedAt: Date?) -> String {
        guard let status else { return "No run" }
        let base: String
        switch status {
        case .running:
            base = "Running"
        case .completed:
            base = "Completed"
        case .failed:
            base = "Failed"
        case .cancelled:
            base = "Cancelled"
        }
        guard let finishedAt else { return base }
        return "\(base) · \(shortDateTime(finishedAt))"
    }

    private func totalDurationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return "No run" }
        let normalized = max(0, duration)
        guard normalized > 0 else { return "0s" }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = normalized >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = [.dropLeading]
        return formatter.string(from: normalized) ?? "\(Int(normalized.rounded()))s"
    }

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func analyticsMetricCard(
        title: String,
        value: String,
        subtitle: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func dailyTrendColumn(_ point: AppViewModel.ModeRecommendationDailyPoint) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.purple)
                    .frame(width: 7, height: trendBarHeight(point.recommendedAgentCount))
                RoundedRectangle(cornerRadius: 2)
                    .fill(.blue)
                    .frame(width: 7, height: trendBarHeight(point.recommendedPipelineCount))
            }
            .frame(height: 44, alignment: .bottom)

            Text(shortDayLabel(for: point.dayStart))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(
            "Recommended Agent \(point.recommendedAgentCount), Recommended Pipeline \(point.recommendedPipelineCount)"
        )
    }

    private func analyticsLegendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func trendBarHeight(_ value: Int) -> CGFloat {
        guard value > 0 else { return 0 }
        let raw = CGFloat(value) / CGFloat(maxDailyTrendValue) * 42
        return max(2, raw)
    }

    private func shortDayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    private func percentageText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func openModeAnalyticsLogInFinder() {
        let logURL = vm.modeAnalyticsLogURL
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([logURL.deletingLastPathComponent()])
        }
    }

    private func exportModeAnalyticsLog() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultAnalyticsExportFileName
        panel.title = "Export Mode Insights Log"
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
            try vm.exportModeAnalyticsLog(to: destinationURL)
            analyticsStatusIsError = false
            analyticsStatusMessage = "Exported to \(destinationURL.path)"
        } catch {
            analyticsStatusIsError = true
            analyticsStatusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func clearModeAnalyticsLog() {
        vm.clearModeAnalyticsLog()
        analyticsStatusIsError = false
        analyticsStatusMessage = "Local mode insights log cleared."
    }

    private var defaultAnalyticsExportFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "mode-analytics-\(formatter.string(from: Date())).jsonl"
    }
}
