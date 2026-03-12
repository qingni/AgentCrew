import SwiftUI

enum SidebarSection: Hashable {
    case pipelines
    case interactive
}

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showNewPipeline = false
    @State private var showAutoPlanner = false
    @State private var showDemoProjectPicker = false
    @State private var showSettings = false
    @State private var editingPipeline: Pipeline?
    @State private var selectedSection: SidebarSection = .pipelines
    @State private var expandedProjectIDs: Set<String> = []

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            switch selectedSection {
            case .interactive:
                InteractiveView()
            case .pipelines:
                if vm.pipelines.isEmpty {
                    WelcomeView(
                        onNewPipeline: { showNewPipeline = true },
                        onAIGenerate: { showAutoPlanner = true },
                        onLoadDemo: { showDemoProjectPicker = true }
                    )
                } else if let pipeline = vm.selectedPipeline {
                    PipelineEditorView(pipeline: pipeline)
                } else {
                    ContentUnavailableView(
                        "Select a Pipeline",
                        systemImage: "sidebar.left",
                        description: Text("Choose a pipeline from the sidebar to view and edit it.")
                    )
                }
            }
        } detail: {
            if selectedSection == .interactive {
                ContentUnavailableView(
                    "Interactive Mode",
                    systemImage: "terminal",
                    description: Text("The terminal session runs in the content area.")
                )
            } else if let step = vm.selectedStep, let pipeline = vm.selectedPipeline {
                StepDetailView(step: step, pipelineID: pipeline.id)
            } else if vm.selectedPipeline != nil {
                StepPlaceholderView()
            } else {
                ContentUnavailableView(
                    "No Step Selected",
                    systemImage: "doc.text",
                    description: Text("Select a step to view its details.")
                )
            }
        }
        .sheet(isPresented: $showNewPipeline) { NewPipelineSheet() }
        .sheet(isPresented: $showAutoPlanner) { AutoPlannerSheet() }
        .sheet(isPresented: $showDemoProjectPicker) { DemoProjectSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(item: $editingPipeline) { pipeline in
            EditPipelineSheet(pipeline: pipeline)
        }
        .overlay {
            if vm.showFlowchart, let pipeline = vm.selectedPipeline {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { vm.showFlowchart = false }

                    PipelineFlowchartView(pipeline: pipeline)
                        .environmentObject(vm)
                        .frame(maxWidth: 780, maxHeight: 600)
                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.separator, lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: vm.showFlowchart)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $vm.selectedPipelineID) {
            Section("AI") {
                Button {
                    showAutoPlanner = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Pipeline Generator")
                                .font(.subheadline.weight(.semibold))
                            Text("Describe task -> auto-create pipeline")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .foregroundStyle(.purple)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.purple.opacity(0.10))
                )
            }

            Section("Projects") {
                ForEach(vm.projectGroups) { project in
                    DisclosureGroup(isExpanded: projectExpansionBinding(projectID: project.id)) {
                        ForEach(project.pipelines) { pipeline in
                            pipelineRow(pipeline)
                                .padding(.leading, 8)
                        }
                    } label: {
                        projectHeader(project)
                    }
                }
            }

            Section("Tools") {
                Button {
                    selectedSection = .interactive
                    vm.selectedPipelineID = nil
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Interactive Terminal")
                            Text("Codex / Claude / Cursor")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "terminal")
                            .foregroundStyle(.purple)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
                .background(
                    selectedSection == .interactive
                        ? RoundedRectangle(cornerRadius: 6).fill(.purple.opacity(0.12))
                        : nil
                )
            }
        }
        .onChange(of: vm.selectedPipelineID) { _, newValue in
            if newValue != nil {
                selectedSection = .pipelines
            }
        }
        .onAppear {
            if expandedProjectIDs.isEmpty {
                expandedProjectIDs = Set(vm.projectGroups.map(\.id))
            }
        }
        .onChange(of: vm.projectGroups.map(\.id)) { oldIDs, newIDs in
            let oldSet = Set(oldIDs)
            let newSet = Set(newIDs)
            expandedProjectIDs.formIntersection(newSet)
            let added = newSet.subtracting(oldSet)
            expandedProjectIDs.formUnion(added)
        }
        .navigationTitle("AI CLI Tools")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showAutoPlanner = true
                } label: {
                    Label("AI Generate", systemImage: "sparkles")
                }
                .help("AI Pipeline Generator")

                Menu {
                    Button("New Pipeline", systemImage: "plus") { showNewPipeline = true }
                    Divider()
                    Button("Load Demo", systemImage: "doc.on.clipboard") { showDemoProjectPicker = true }
                } label: {
                    Image(systemName: "plus")
                }
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if vm.pipelines.isEmpty && selectedSection != .interactive {
                VStack(spacing: 8) {
                    Text("Get started by creating your first pipeline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Create Pipeline") { showNewPipeline = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func pipelineRow(_ pipeline: Pipeline) -> some View {
        NavigationLink(value: pipeline.id) {
            HStack {
                Image(systemName: "flowchart")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pipeline.name).lineLimit(1)
                    Text(
                        "\(pipeline.stages.count) stages · \(pipeline.allSteps.count) steps"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if pipeline.isLockedAfterRun {
                    Label("Locked", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(.vertical, 2)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") {
                editingPipeline = pipeline
            }
            .disabled(vm.isPipelineExecuting(pipeline.id) || pipeline.isLockedAfterRun)

            Button("Delete", role: .destructive) {
                vm.deletePipeline(pipeline.id)
            }
        }
    }

    @ViewBuilder
    private func projectHeader(_ project: AppViewModel.ProjectGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(project.workingDirectory)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(project.pipelines.count)")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 2)
    }

    private func projectExpansionBinding(projectID: String) -> Binding<Bool> {
        Binding(
            get: { expandedProjectIDs.contains(projectID) },
            set: { isExpanded in
                if isExpanded {
                    expandedProjectIDs.insert(projectID)
                } else {
                    expandedProjectIDs.remove(projectID)
                }
            }
        )
    }
}

// MARK: - Welcome View

private struct WelcomeView: View {
    let onNewPipeline: () -> Void
    let onAIGenerate: () -> Void
    let onLoadDemo: () -> Void

    @State private var isHoveringAI = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "flowchart.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.blue.gradient)
                    Text("AI CLI Orchestrator")
                        .font(.largeTitle.bold())
                    Text("Mix Codex, Claude & Cursor in one pipeline.\nCode, review, fix, retry \u{2014} all automated.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                Button(action: onAIGenerate) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(.purple.gradient)
                                .frame(width: 52, height: 52)
                            Image(systemName: "sparkles")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .symbolEffect(.pulse, options: .repeating, isActive: isHoveringAI)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI Pipeline Generator")
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text("Describe what you want to do and let AI build the pipeline for you")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.purple)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.purple.opacity(isHoveringAI ? 0.15 : 0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(.purple.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                .buttonStyle(.plain)
                .onHover { isHoveringAI = $0 }
                .padding(.horizontal)

                HStack(spacing: 16) {
                    ActionCard(
                        icon: "plus.rectangle.on.folder",
                        color: .blue,
                        title: "New Pipeline",
                        subtitle: "Manually build stages & steps",
                        action: onNewPipeline
                    )
                    ActionCard(
                        icon: "doc.on.clipboard",
                        color: .orange,
                        title: "Load Demo",
                        subtitle: "See a sample pipeline in action",
                        action: onLoadDemo
                    )
                }
                .padding(.horizontal)

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("How It Works").font(.headline)

                        WorkflowStep(number: 1, icon: "sparkles", color: .purple,
                                     title: "Describe Your Task",
                                     detail: "Tell the AI what you want to build or fix \u{2014} it generates a full pipeline automatically.")

                        WorkflowStep(number: 2, icon: "rectangle.stack", color: .indigo,
                                     title: "Review Stages & Steps",
                                     detail: "Each stage groups related steps. Choose parallel (all at once) or sequential (one by one).")

                        WorkflowStep(number: 3, icon: "gearshape.2", color: .teal,
                                     title: "Customize if Needed",
                                     detail: "Adjust prompts, tools, and dependencies \u{2014} or just run with the AI defaults.")

                        WorkflowStep(number: 4, icon: "play.fill", color: .green,
                                     title: "Run the Pipeline",
                                     detail: "The DAG scheduler executes steps wave-by-wave, respecting dependencies.")
                    }
                    .padding(8)
                }
                .padding(.horizontal)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Available Tools").font(.headline)
                        HStack(spacing: 20) {
                            ToolBadge(tool: .codex, role: "Coding + verify/fix")
                            ToolBadge(tool: .claude, role: "Optional analysis")
                            ToolBadge(tool: .cursor, role: "Code review")
                        }
                    }
                    .padding(8)
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
    }
}

private struct ActionCard: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(color)
                Text(title).font(.subheadline.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct WorkflowStep: View {
    let number: Int
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(color.gradient).frame(width: 28, height: 28)
                Text("\(number)").font(.caption.bold()).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(title).font(.subheadline.bold())
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ToolBadge: View {
    let tool: ToolType
    let role: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: tool.iconName)
                .font(.title2)
                .foregroundStyle(tool.tintColor)
            Text(tool.displayName).font(.caption.bold())
            Text(role).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Step Placeholder

private struct StepPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.point.left")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Select a Step")
                .font(.title3.bold())
            Text("Click on any step in the pipeline editor\nto configure its command, prompt, and dependencies.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - New Pipeline Sheet

private struct NewPipelineSheet: View {
    private enum ProjectSelectionMode: String, CaseIterable, Identifiable {
        case existing = "Existing Project"
        case new = "New Project"
        var id: Self { self }
    }

    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var workingDirectory = ""
    @State private var lastSuggestedName = ""
    @State private var projectSelectionMode: ProjectSelectionMode = .new
    @State private var selectedExistingProjectDirectory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Pipeline").font(.title2.bold())

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
                        .onChange(of: selectedExistingProjectDirectory) { _, newValue in
                            syncNameWithWorkingDirectory(newValue, force: false)
                        }

                        Text("Reuse an existing project directory and create another pipeline under it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            TextField("Select project folder", text: $workingDirectory)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: workingDirectory) { _, newValue in
                                    syncNameWithWorkingDirectory(newValue, force: false)
                                }
                            Button("Browse") { browseFolder() }
                        }
                        Text("Choose which project this pipeline should run against.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }

            TextField("Pipeline Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Each project can contain multiple pipelines, and all CLI steps run inside the selected project directory.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    vm.createPipeline(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        workingDirectory: targetWorkingDirectory
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetWorkingDirectory.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: configureProjectSelectionDefaults)
        .onChange(of: projectSelectionMode) { _, newMode in
            if newMode == .existing, selectedExistingProjectDirectory.isEmpty {
                selectedExistingProjectDirectory = existingProjects.first?.workingDirectory ?? ""
            }
            if newMode == .existing {
                syncNameWithWorkingDirectory(selectedExistingProjectDirectory, force: false)
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
            syncNameWithWorkingDirectory(url.path, force: true)
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
            if projectSelectionMode == .existing {
                syncNameWithWorkingDirectory(firstProject.workingDirectory, force: false)
            }
        } else {
            projectSelectionMode = .new
            selectedExistingProjectDirectory = ""
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

private struct DemoProjectSheet: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var workingDirectory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Load Demo Pipeline").font(.title2.bold())

            GroupBox("Project") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Select project folder", text: $workingDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse") { browseFolder() }
                    }
                    Text("The demo pipeline will run all of its steps inside this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Load Demo") {
                    vm.createDemoPipeline(workingDirectory: workingDirectory)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workingDirectory.isEmpty)
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
        }
    }
}

// MARK: - Settings Sheet

private struct SettingsSheet: View {
    @EnvironmentObject var vm: AppViewModel
    @ObservedObject private var profileManager = CLIProfileManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var detectionResults: [CLIProfileManager.DetectionResult] = []
    @State private var isDetecting = false
    @State private var recommendedProfile: CLIProfile?
    @State private var showPolicyEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.bold())

            GroupBox("CLI Environment") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Environment")
                            .font(.subheadline)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { profileManager.activeProfile.id },
                            set: { newID in
                                if let profile = CLIProfile.builtInProfiles.first(where: { $0.id == newID }) {
                                    profileManager.selectProfile(profile)
                                }
                            }
                        )) {
                            ForEach(CLIProfile.builtInProfiles, id: \.id) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                    }

                    Divider()

                    if isDetecting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Detecting CLI tools...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !detectionResults.isEmpty {
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: 6) {
                            ForEach(detectionResults, id: \.executable) { result in
                                HStack(spacing: 6) {
                                    Image(systemName: result.found ? "checkmark.circle.fill" : "xmark.circle")
                                        .foregroundStyle(result.found ? .green : .secondary)
                                        .font(.caption)
                                    Text(result.executable)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 8)
                                .background(
                                    result.found
                                        ? Color.green.opacity(0.08)
                                        : Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            }
                        }
                    }

                    if let recommended = recommendedProfile,
                       recommended.id != profileManager.activeProfile.id {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Detected environment mismatch")
                                    .font(.caption.bold())
                                Text("Your system has **\(recommended.name)** tools, but the current environment is set to **\(profileManager.activeProfile.name)**.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Switch to \(recommended.name)") {
                                withAnimation { profileManager.selectProfile(recommended) }
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    ForEach(ToolType.allCases) { tool in
                        cliToolRow(tool)
                    }

                    Text("Switching environment updates all pipeline steps that don't have a custom command override.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("AI Pipeline Generator") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Default Model", text: $vm.llmConfig.model)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("Customize planner policy when needed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit Prompt Policy…") {
                            showPolicyEditor = true
                        }
                        .controlSize(.small)
                    }

                    if trimmedCustomPolicy.isEmpty {
                        Text("Using built-in planning policy.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Custom policy enabled")
                            .font(.caption2.bold())
                        Text(trimmedCustomPolicy)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await runDetection() }
        .sheet(isPresented: $showPolicyEditor) {
            PlanningPolicyEditorSheet(customPolicy: customPolicyBinding)
        }
    }

    @ViewBuilder
    private func cliToolRow(_ tool: ToolType) -> some View {
        let config = profileManager.activeProfile.config(for: tool)
        HStack(spacing: 6) {
            Image(systemName: tool.iconName)
                .foregroundStyle(tool.tintColor)
                .frame(width: 16)
            Text(tool.displayName)
                .font(.caption.bold())
                .frame(width: 48, alignment: .leading)
            Text(config.executable)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var customPolicyBinding: Binding<String> {
        Binding(
            get: { vm.llmConfig.customPolicy },
            set: { vm.llmConfig.customPolicy = $0 }
        )
    }

    private var trimmedCustomPolicy: String {
        vm.llmConfig.customPolicy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runDetection() async {
        isDetecting = true
        let (results, recommended) = await profileManager.detectEnvironment()
        withAnimation(.easeInOut(duration: 0.3)) {
            detectionResults = results
            recommendedProfile = recommended
            isDetecting = false
        }
    }
}
