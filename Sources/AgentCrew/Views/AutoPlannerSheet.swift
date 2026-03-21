import SwiftUI

struct AutoPlannerSheet: View {
    private enum ProjectSelectionMode: String, CaseIterable, Identifiable {
        case existing = "existing"
        case new = "new"
        var id: Self { self }

        var title: String {
            switch self {
            case .existing:
                return L10n.text("project.existing", fallback: "Existing Project")
            case .new:
                return L10n.text("project.new", fallback: "New Project")
            }
        }
    }

    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var prompt = ""
    @State private var workingDirectory = ""
    @State private var projectSelectionMode: ProjectSelectionMode = .new
    @State private var selectedExistingProjectDirectory = ""
    @State private var generationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("home.aiPipelineGenerator", fallback: "AI Pipeline Generator")).font(.title2.bold())
            Text(L10n.text("planner.subtitle", fallback: "Describe your task in natural language and the AI will generate a multi-step pipeline."))
                .font(.callout).foregroundStyle(.secondary)

            GroupBox(L10n.text("common.project", fallback: "Project")) {
                VStack(alignment: .leading, spacing: 8) {
                    if !existingProjects.isEmpty {
                        Picker(L10n.text("project.source", fallback: "Project Source"), selection: $projectSelectionMode) {
                            ForEach(ProjectSelectionMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if projectSelectionMode == .existing, !existingProjects.isEmpty {
                        Picker(L10n.text("project.reuseExisting", fallback: "Reuse Existing Project"), selection: $selectedExistingProjectDirectory) {
                            ForEach(existingProjects, id: \.workingDirectory) { project in
                                Text("\(project.displayName) (\(project.pipelines.count) \(L10n.text("project.pipelines", fallback: "pipelines")))")
                                    .tag(project.workingDirectory)
                            }
                        }
                        .pickerStyle(.menu)
                        Text(L10n.text("project.reuseExistingDescription", fallback: "Reuse an existing project to generate another pipeline."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            TextField(L10n.text("project.selectFolder", fallback: "Select project folder"), text: $workingDirectory)
                                .textFieldStyle(.roundedBorder)
                            Button(L10n.text("common.browse", fallback: "Browse")) { browseFolder() }
                        }
                        Text(L10n.text("project.generatedPipelineRunsAgainst", fallback: "Choose which project this generated pipeline should run against."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
            .disabled(vm.isPlanningInProgress)

            GroupBox(L10n.text("planner.taskDescription", fallback: "Task Description")) {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                    .padding(4)
            }
            .disabled(vm.isPlanningInProgress)

            GroupBox(L10n.text("planner.policy", fallback: "Planning Policy")) {
                VStack(alignment: .leading, spacing: 8) {
                    if trimmedCustomPolicy.isEmpty {
                        Text(L10n.text("planner.currentBuiltInOnly", fallback: "Current prompt: built-in planner prompt only."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(L10n.text("planner.customizePath", fallback: "To customize it, go to Settings > AI Pipeline Generator > Edit Prompt Policy..."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("planner.currentBuiltInPlusCustom", fallback: "Current prompt: built-in planner prompt + custom policy from Settings."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(L10n.text("planner.editPath", fallback: "Edit path: Settings > AI Pipeline Generator > Edit Prompt Policy..."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(trimmedCustomPolicy)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(vm.isPlanningInProgress)

            if showProgressPanel {
                planningProgressPanel
            }

            if let err = vm.planningError {
                Label(err, systemImage: planningErrorIcon)
                    .font(.caption)
                    .foregroundStyle(planningErrorColor)
            }

            HStack {
                Button(vm.isPlanningInProgress ? L10n.text("common.stop", fallback: "Stop") : L10n.text("common.cancel", fallback: "Cancel")) {
                    if vm.isPlanningInProgress {
                        generationTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if vm.isPlanningInProgress {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressStatusText)
                        .font(.callout)
                }
                Button(L10n.text("planner.generate", fallback: "Generate Pipeline")) {
                    generationTask?.cancel()
                    generationTask = Task {
                        await vm.generatePipeline(from: prompt, workingDirectory: targetWorkingDirectory)
                        await MainActor.run {
                            generationTask = nil
                            if vm.planningError == nil { dismiss() }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || targetWorkingDirectory.isEmpty
                    || vm.isPlanningInProgress
                )
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 520)
        .onAppear {
            vm.resetPlanningState()
            configureProjectSelectionDefaults()
        }
        .onDisappear {
            generationTask?.cancel()
            generationTask = nil
        }
        .onChange(of: projectSelectionMode) { _, newMode in
            if newMode == .existing, selectedExistingProjectDirectory.isEmpty {
                selectedExistingProjectDirectory = existingProjects.first?.workingDirectory ?? ""
            }
        }
    }

    private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private var existingProjects: [AppViewModel.ProjectGroup] {
        vm.projectGroups.filter { !$0.workingDirectory.isEmpty }
    }

    private var trimmedCustomPolicy: String {
        vm.llmConfig.customPolicy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var targetWorkingDirectory: String {
        switch projectSelectionMode {
        case .existing:
            return selectedExistingProjectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        case .new:
            return workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func configureProjectSelectionDefaults() {
        if let firstProject = existingProjects.first {
            projectSelectionMode = .existing
            selectedExistingProjectDirectory = firstProject.workingDirectory
        } else {
            projectSelectionMode = .new
            selectedExistingProjectDirectory = ""
        }
    }

    private var showProgressPanel: Bool {
        vm.isPlanningInProgress || !vm.planningLogs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var progressStatusText: String {
        if let phase = vm.planningPhase {
            return "\(L10n.text("planner.generating", fallback: "Generating…")) \(phase.title)"
        }
        return L10n.text("planner.generating", fallback: "Generating…")
    }

    private var planningErrorIcon: String {
        vm.planningError?.localizedCaseInsensitiveContains("cancelled") == true
            ? "stop.circle"
            : "xmark.circle"
    }

    private var planningErrorColor: Color {
        vm.planningError?.localizedCaseInsensitiveContains("cancelled") == true
            ? .orange
            : .red
    }

    private var planningProgressPanel: some View {
        GroupBox(L10n.text("planner.generationProgress", fallback: "Generation Progress")) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PlanningPhase.allCases, id: \.self) { phase in
                    PlanningPhaseRow(
                        title: phase.title,
                        state: stateForPhase(phase)
                    )
                }

                Divider().padding(.vertical, 2)

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(planningLogText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("planning-log-bottom")
                    }
                    .frame(minHeight: 120, maxHeight: 170)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: vm.planningLogs) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("planning-log-bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var planningLogText: String {
        let trimmed = vm.planningLogs.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L10n.text("planner.waitingOutput", fallback: "Waiting for agent CLI output...")
        }
        return trimmed
    }

    private func stateForPhase(_ phase: PlanningPhase) -> PlanningPhaseState {
        guard let current = vm.planningPhase else {
            return .pending
        }
        if phase.rawValue < current.rawValue {
            return .completed
        }
        if phase == current {
            return vm.isPlanningInProgress ? .running : .completed
        }
        return .pending
    }
}

private enum PlanningPhaseState {
    case pending
    case running
    case completed
}

private struct PlanningPhaseRow: View {
    let title: String
    let state: PlanningPhaseState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(color)
                .frame(width: 14)
            Text(title)
                .font(.caption)
                .foregroundStyle(state == .pending ? .secondary : .primary)
            Spacer()
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(color)
        }
    }

    private var iconName: String {
        switch state {
        case .pending: "circle"
        case .running: "clock.fill"
        case .completed: "checkmark.circle.fill"
        }
    }

    private var statusText: String {
        switch state {
        case .pending: L10n.text("status.pending", fallback: "Pending")
        case .running: L10n.text("status.runningProgress", fallback: "Running")
        case .completed: L10n.text("common.done", fallback: "Done")
        }
    }

    private var color: Color {
        switch state {
        case .pending: .secondary
        case .running: .blue
        case .completed: .green
        }
    }
}

struct PlanningPolicyEditorSheet: View {
    @Binding var customPolicy: String
    @Environment(\.dismiss) private var dismiss
    @State private var draftPolicy: String = ""
    @State private var showBuiltInPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("planner.editPolicy", fallback: "Edit Planning Policy"))
                .font(.title3.bold())
            Text(L10n.text("planner.policyDescription", fallback: "This policy is appended to the planner prompt. Keep it concise and outcome-focused."))
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $draftPolicy)
                .font(.body)
                .frame(minHeight: 220)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button(L10n.text("planner.resetBuiltIn", fallback: "Reset to Built-in")) {
                    draftPolicy = ""
                }
                Button(L10n.text("planner.viewBuiltInPrompt", fallback: "View Built-in Prompt")) {
                    showBuiltInPrompt = true
                }
                Spacer()
                Button(L10n.text("common.cancel", fallback: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("common.save", fallback: "Save")) {
                    customPolicy = draftPolicy.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear {
            draftPolicy = customPolicy
        }
        .sheet(isPresented: $showBuiltInPrompt) {
            BuiltInPlannerPromptSheet(promptText: AIPlanner.builtInPromptPreview())
        }
    }
}

private struct BuiltInPlannerPromptSheet: View {
    let promptText: String
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("planner.builtInPrompt", fallback: "Built-in Planner Prompt"))
                .font(.title3.bold())
            Text(L10n.text("planner.builtInPromptDescription", fallback: "Read-only reference. This is the built-in planner prompt used before your custom policy is appended."))
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(promptText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button(didCopy ? L10n.text("common.copied", fallback: "Copied") : L10n.text("common.copy", fallback: "Copy")) {
                    copyPromptToClipboard()
                }
                .controlSize(.small)
                Spacer()
                Button(L10n.text("common.close", fallback: "Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func copyPromptToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(promptText, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { didCopy = false }
        }
    }
}
