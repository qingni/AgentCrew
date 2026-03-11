import SwiftUI

struct AutoPlannerSheet: View {
    private enum ProjectSelectionMode: String, CaseIterable, Identifiable {
        case existing = "Existing Project"
        case new = "New Project"
        var id: Self { self }
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
            Text("AI Pipeline Generator").font(.title2.bold())
            Text("Describe your task in natural language and the AI will generate a multi-step pipeline.")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox("Project") {
                VStack(alignment: .leading, spacing: 8) {
                    if !existingProjects.isEmpty {
                        Picker("Project Source", selection: $projectSelectionMode) {
                            ForEach(ProjectSelectionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if projectSelectionMode == .existing, !existingProjects.isEmpty {
                        Picker("Reuse Existing Project", selection: $selectedExistingProjectDirectory) {
                            ForEach(existingProjects, id: \.workingDirectory) { project in
                                Text("\(project.displayName) (\(project.pipelines.count) pipelines)")
                                    .tag(project.workingDirectory)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Reuse an existing project to generate another pipeline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            TextField("Select project folder", text: $workingDirectory)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse") { browseFolder() }
                        }
                        Text("Choose which project this generated pipeline should run against.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
            .disabled(vm.isPlanningInProgress)

            GroupBox("Task Description") {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                    .padding(4)
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
                Button(vm.isPlanningInProgress ? "Stop" : "Cancel") {
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
                Button("Generate Pipeline") {
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
            return "Generating… \(phase.title)"
        }
        return "Generating…"
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
        GroupBox("Generation Progress") {
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
            return "Waiting for agent CLI output..."
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
        case .pending: "Pending"
        case .running: "Running"
        case .completed: "Done"
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
