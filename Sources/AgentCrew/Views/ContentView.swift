import SwiftUI

enum SidebarSection: Hashable {
    case home
    case pipelines
    case modeAnalytics
}

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showNewPipeline = false
    @State private var showAutoPlanner = false
    @State private var showDemoProjectPicker = false
    @State private var showSettings = false
    @State private var editingPipeline: Pipeline?
    @State private var selectedSection: SidebarSection = .pipelines
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var expandedProjectIDs: Set<String> = []

    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            sidebar
        } content: {
            switch selectedSection {
            case .home:
                WelcomeView(
                    onNewPipeline: { showNewPipeline = true },
                    onAIGenerate: { showAutoPlanner = true },
                    onLoadDemo: { showDemoProjectPicker = true }
                )
            case .modeAnalytics:
                ModeAnalyticsView()
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
                        L10n.text("content.selectPipeline", fallback: "Select a Pipeline"),
                        systemImage: "sidebar.left",
                        description: Text(L10n.text("content.selectPipelineDescription", fallback: "Choose a pipeline from the sidebar to view and edit it."))
                    )
                }
            }
        } detail: {
            if selectedSection == .home {
                ContentUnavailableView(
                    L10n.text("common.home", fallback: "Home"),
                    systemImage: "house",
                    description: Text(L10n.text("content.homeDescription", fallback: "Use the welcome page to create a pipeline, generate one with AI, or load a demo."))
                )
            } else if selectedSection == .modeAnalytics {
                ContentUnavailableView(
                    L10n.text("insights.modeInsights", fallback: "Mode Insights"),
                    systemImage: "chart.bar.fill",
                    description: Text(L10n.text("content.insightsDescription", fallback: "Insights dashboards are shown in the content area."))
                )
            } else if let step = vm.selectedStep, let pipeline = vm.selectedPipeline {
                StepDetailView(step: step, pipelineID: pipeline.id)
            } else if vm.selectedPipeline != nil {
                StepPlaceholderView()
            } else {
                ContentUnavailableView(
                    L10n.text("content.noStepSelected", fallback: "No Step Selected"),
                    systemImage: "doc.text",
                    description: Text(L10n.text("content.noStepSelectedDescription", fallback: "Select a step to view its details."))
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
        .onAppear {
            // Recover sidebar after prior column-visibility experiments.
            splitViewVisibility = .all
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $vm.selectedPipelineID) {
            Section(L10n.text("common.ai", fallback: "AI")) {
                Button {
                    selectedSection = .home
                    vm.selectedPipelineID = nil
                    vm.selectedStepID = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("home.aiPipelineGenerator", fallback: "AI Pipeline Generator"))
                                .font(.subheadline.weight(.semibold))
                            Text(L10n.text("content.describeTaskAutoCreate", fallback: "Describe task -> auto-create pipeline"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.purple.opacity(selectedSection == .home ? 0.18 : 0.10))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Section(L10n.text("common.projects", fallback: "Projects")) {
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

            Section(L10n.text("common.insights", fallback: "Insights")) {
                Button {
                    selectedSection = .modeAnalytics
                    vm.selectedPipelineID = nil
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("insights.modeInsights", fallback: "Mode Insights"))
                            Text(L10n.text("insights.recommendationVsCurrent", fallback: "Recommendation vs current mode"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "chart.bar.fill")
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        selectedSection == .modeAnalytics
                            ? RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.12))
                            : nil
                    )
                    .padding(.horizontal, -8)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
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
        .navigationTitle(L10n.text("nav.aiCliTools", fallback: "AI CLI Tools"))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showAutoPlanner = true
                } label: {
                    Label(L10n.text("toolbar.aiGenerate", fallback: "AI Generate"), systemImage: "sparkles")
                }
                .help(L10n.text("home.aiPipelineGenerator", fallback: "AI Pipeline Generator"))

                Menu {
                    Button(L10n.text("pipeline.new", fallback: "New Pipeline"), systemImage: "plus") { showNewPipeline = true }
                    Divider()
                    Button(L10n.text("pipeline.loadDemo", fallback: "Load Demo"), systemImage: "doc.on.clipboard") { showDemoProjectPicker = true }
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    selectedSection = .modeAnalytics
                    vm.selectedPipelineID = nil
                } label: {
                    Image(systemName: "chart.bar.fill")
                }
                .help(L10n.text("insights.modeInsights", fallback: "Mode Insights"))
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if vm.pipelines.isEmpty {
                VStack(spacing: 8) {
                    Text(L10n.text("content.getStarted", fallback: "Get started by creating your first pipeline"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L10n.text("pipeline.create", fallback: "Create Pipeline")) { showNewPipeline = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func pipelineRow(_ pipeline: Pipeline) -> some View {
        let isRunning = vm.isPipelineExecuting(pipeline.id)
        let isAgentRunning = vm.isAgentExecuting(pipeline.id)
        NavigationLink(value: pipeline.id) {
            HStack {
                Image(systemName: "flowchart")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pipeline.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if pipeline.isAIGenerated {
                            Text(L10n.text("common.ai", fallback: "AI"))
                                .font(.caption2.bold())
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.purple.opacity(0.14), in: Capsule())
                                .fixedSize()
                        }
                        if pipeline.preferredRunMode == .agent {
                            Text(L10n.text("mode.agent", fallback: "Agent"))
                                .font(.caption2.bold())
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.orange.opacity(0.14), in: Capsule())
                                .fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(
                        "\(pipeline.stages.count) \(L10n.text("common.stages", fallback: "stages")) · \(pipeline.allSteps.count) \(L10n.text("common.steps", fallback: "steps"))"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if isRunning {
                    Image(systemName: isAgentRunning ? "sparkles" : "play.circle.fill")
                        .font(.caption)
                        .foregroundStyle(isAgentRunning ? .purple : .green)
                        .symbolEffect(.pulse, options: .repeating)
                        .help(isAgentRunning ? L10n.text("content.agentRunning", fallback: "Agent is running") : L10n.text("content.pipelineRunning", fallback: "Pipeline is running"))
                }
            }
            .padding(.vertical, 2)
        }
        .contextMenu {
            Button(L10n.text("common.edit", fallback: "Edit"), systemImage: "pencil") {
                editingPipeline = pipeline
            }
            .disabled(vm.isPipelineExecuting(pipeline.id))

            Button(L10n.text("common.delete", fallback: "Delete"), role: .destructive) {
                vm.deletePipeline(pipeline.id)
            }
            .disabled(vm.isPipelineExecuting(pipeline.id) || vm.isPipelineQueued(pipeline.id))
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
                    Text(L10n.text("home.title", fallback: "AI CLI Orchestrator"))
                        .font(.largeTitle.bold())
                    Text(L10n.text("home.subtitle", fallback: "Mix Codex, Claude & Cursor in one pipeline.\nCode, review, fix, retry — all automated."))
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
                            Text(L10n.text("home.aiPipelineGenerator", fallback: "AI Pipeline Generator"))
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text(L10n.text("home.aiPipelineGeneratorSubtitle", fallback: "Describe what you want to do and let AI build the pipeline for you"))
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
                        title: L10n.text("pipeline.new", fallback: "New Pipeline"),
                        subtitle: L10n.text("pipeline.manualBuild", fallback: "Manually build stages & steps"),
                        action: onNewPipeline
                    )
                    ActionCard(
                        icon: "doc.on.clipboard",
                        color: .orange,
                        title: L10n.text("pipeline.loadDemo", fallback: "Load Demo"),
                        subtitle: L10n.text("pipeline.loadDemoSubtitle", fallback: "See a sample pipeline in action"),
                        action: onLoadDemo
                    )
                }
                .padding(.horizontal)

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.text("common.howItWorks", fallback: "How It Works")).font(.headline)

                        WorkflowStep(number: 1, icon: "sparkles", color: .purple,
                                     title: L10n.text("home.workflow.describeTask", fallback: "Describe Your Task"),
                                     detail: L10n.text("home.workflow.describeTaskDetail", fallback: "Tell the AI what you want to build or fix — it generates a full pipeline automatically."))

                        WorkflowStep(number: 2, icon: "rectangle.stack", color: .indigo,
                                     title: L10n.text("home.workflow.review", fallback: "Review Stages & Steps"),
                                     detail: L10n.text("home.workflow.reviewDetail", fallback: "Each stage groups related steps. Choose parallel (all at once) or sequential (one by one)."))

                        WorkflowStep(number: 3, icon: "gearshape.2", color: .teal,
                                     title: L10n.text("home.workflow.customize", fallback: "Customize if Needed"),
                                     detail: L10n.text("home.workflow.customizeDetail", fallback: "Adjust prompts, tools, and dependencies — or just run with the AI defaults."))

                        WorkflowStep(number: 4, icon: "play.fill", color: .green,
                                     title: L10n.text("home.workflow.run", fallback: "Run the Pipeline"),
                                     detail: L10n.text("home.workflow.runDetail", fallback: "The DAG scheduler executes steps wave-by-wave, respecting dependencies."))
                    }
                    .padding(8)
                }
                .padding(.horizontal)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("home.availableTools", fallback: "Available Tools")).font(.headline)
                        HStack(spacing: 20) {
                            ToolBadge(tool: .codex, role: L10n.text("tool.role.codex", fallback: "Coding + verify/fix"))
                            ToolBadge(tool: .claude, role: L10n.text("tool.role.claude", fallback: "Optional analysis"))
                            ToolBadge(tool: .cursor, role: L10n.text("tool.role.cursor", fallback: "Code review"))
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
            Text(L10n.text("content.selectStep", fallback: "Select a Step"))
                .font(.title3.bold())
            Text(L10n.text("content.selectStepDescription", fallback: "Click on any step in the pipeline editor\nto configure its command, prompt, and dependencies."))
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
    @State private var name = ""
    @State private var workingDirectory = ""
    @State private var lastSuggestedName = ""
    @State private var projectSelectionMode: ProjectSelectionMode = .new
    @State private var selectedExistingProjectDirectory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("pipeline.new", fallback: "New Pipeline")).font(.title2.bold())

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
                        .onChange(of: selectedExistingProjectDirectory) { _, newValue in
                            syncNameWithWorkingDirectory(newValue, force: false)
                        }

                        Text(L10n.text("project.reuseExistingCreateAnother", fallback: "Reuse an existing project directory and create another pipeline under it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            TextField(L10n.text("project.selectFolder", fallback: "Select project folder"), text: $workingDirectory)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: workingDirectory) { _, newValue in
                                    syncNameWithWorkingDirectory(newValue, force: false)
                                }
                            Button(L10n.text("common.browse", fallback: "Browse")) { browseFolder() }
                        }
                        Text(L10n.text("project.pipelineRunsAgainst", fallback: "Choose which project this pipeline should run against."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }

            TextField(L10n.text("pipeline.name", fallback: "Pipeline Name"), text: $name)
                .textFieldStyle(.roundedBorder)

            Text(L10n.text("project.multiplePipelinesHint", fallback: "Each project can contain multiple pipelines, and all CLI steps run inside the selected project directory."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(L10n.text("common.cancel", fallback: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("common.create", fallback: "Create")) {
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
            Text(L10n.text("pipeline.loadDemoPipeline", fallback: "Load Demo Pipeline")).font(.title2.bold())

            GroupBox(L10n.text("common.project", fallback: "Project")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(L10n.text("project.selectFolder", fallback: "Select project folder"), text: $workingDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button(L10n.text("common.browse", fallback: "Browse")) { browseFolder() }
                    }
                    Text(L10n.text("project.demoPipelineRunsInside", fallback: "The demo pipeline will run all of its steps inside this project."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            HStack {
                Button(L10n.text("common.cancel", fallback: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("pipeline.loadDemo", fallback: "Load Demo")) {
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
    @AppStorage(L10n.storageKey) private var appLanguage = AppLanguage.system.rawValue

    @State private var detectionResults: [CLIProfileManager.DetectionResult] = []
    @State private var isDetecting = false
    @State private var showPolicyEditor = false
    @State private var notificationStatusMessage = ""
    @State private var notificationStatusIsError = false
    @State private var isRequestingNotificationPermission = false
    @State private var isSendingNotificationTest = false
    @State private var copiedCommandTool: ToolType?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                    Text(L10n.text("settings.title", fallback: "Settings"))
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox(L10n.text("cli.environment", fallback: "CLI Environment")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(
                                L10n.text("cli.useAlternateMode", fallback: "Use alternate command mode for Codex and Claude"),
                                isOn: Binding(
                                    get: { profileManager.useInternalCommands },
                                    set: { enabled in
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            profileManager.setUseInternalCommands(enabled)
                                        }
                                    }
                                )
                            )

                            Text(
                                profileManager.useInternalCommands
                                    ? L10n.text("cli.alternateModeActive", fallback: "Alternate mode is active. Codex and Claude use alternate command mapping.")
                                    : L10n.text("cli.standardModeActive", fallback: "Standard mode is active. Codex and Claude use standard command mapping.")
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                            Text(L10n.text("cli.cursorFixedMode", fallback: "Cursor stays on a fixed command mode."))
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Divider()

                            if isDetecting {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.text("common.checkingTools", fallback: "Checking tools..."))
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
                                            Text(detectionDisplayName(for: result.executable))
                                                .font(.caption)
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

                            ForEach(ToolType.allCases) { tool in
                                cliToolRow(tool)
                            }

                            Text(L10n.text("cli.modeSwitchUpdatesSteps", fallback: "Switching this mode updates all pipeline steps that don't have a custom command override."))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }

                    GroupBox(L10n.text("settings.interfaceLanguage", fallback: "Interface Language")) {
                        Picker(L10n.text("settings.language", fallback: "Language"), selection: languageBinding) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(8)
                    }

                    GroupBox(L10n.text("home.aiPipelineGenerator", fallback: "AI Pipeline Generator")) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(L10n.text("common.defaultModel", fallback: "Default Model"), text: $vm.llmConfig.model)
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                Text(L10n.text("planner.customizeWhenNeeded", fallback: "Customize planner policy when needed."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(L10n.text("planner.editPromptPolicy", fallback: "Edit Prompt Policy…")) {
                                    showPolicyEditor = true
                                }
                                .controlSize(.small)
                            }

                            if trimmedCustomPolicy.isEmpty {
                                Text(L10n.text("planner.usingBuiltInPolicy", fallback: "Using built-in planning policy."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(L10n.text("planner.customPolicyEnabled", fallback: "Custom policy enabled"))
                                    .font(.caption2.bold())
                                Text(trimmedCustomPolicy)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(8)
                    }

                    GroupBox(L10n.text("execution.scheduling", fallback: "Execution Scheduling")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Stepper(
                                value: $vm.maxConcurrentPipelineRuns,
                                in: 1...4
                            ) {
                                HStack {
                                    Text(L10n.text("execution.maxConcurrentPipelineRuns", fallback: "Max concurrent pipeline runs"))
                                    Spacer()
                                    Text("\(vm.maxConcurrentPipelineRuns)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(L10n.text("execution.sharedDirectorySerialized", fallback: "Pipelines sharing the same working directory are automatically serialized for safety."))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(8)
                    }

                    GroupBox(L10n.text("execution.notifications", fallback: "Execution Notifications")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(L10n.text("execution.enableCompletionNotifications", fallback: "Enable completion notifications"), isOn: executionNotificationsEnabledBinding)
                                .disabled(isRequestingNotificationPermission)

                            if vm.executionNotificationSettings.isEnabled {
                                Toggle(L10n.text("execution.notifyCompleted", fallback: "Notify when completed"), isOn: $vm.executionNotificationSettings.notifyOnCompleted)
                                Toggle(L10n.text("execution.notifyFailed", fallback: "Notify when failed"), isOn: $vm.executionNotificationSettings.notifyOnFailed)
                                Toggle(L10n.text("execution.notifyCancelled", fallback: "Notify when cancelled"), isOn: $vm.executionNotificationSettings.notifyOnCancelled)
                                Toggle(L10n.text("execution.playSound", fallback: "Play sound"), isOn: $vm.executionNotificationSettings.playSound)
                            }

                            Text(notificationAuthorizationHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                Button(L10n.text("execution.sendTestNotification", fallback: "Send Test Notification")) {
                                    sendExecutionTestNotification()
                                }
                                .controlSize(.small)
                                .disabled(!vm.executionNotificationSettings.isEnabled || isSendingNotificationTest)

                                if isRequestingNotificationPermission || isSendingNotificationTest {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Spacer(minLength: 0)
                            }

                            if !notificationStatusMessage.isEmpty {
                                Text(notificationStatusMessage)
                                    .font(.caption2)
                                    .foregroundStyle(notificationStatusIsError ? .red : .secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.text("common.done", fallback: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 700)
        .task {
            await runDetection()
            await vm.refreshExecutionNotificationAuthorizationState()
        }
        .sheet(isPresented: $showPolicyEditor) {
            PlanningPolicyEditorSheet(customPolicy: customPolicyBinding)
        }
        .onChange(of: profileManager.useInternalCommands) { _, _ in
            Task { await runDetection() }
        }
    }

    @ViewBuilder
    private func cliToolRow(_ tool: ToolType) -> some View {
        let commandTemplate = profileManager.activeProfile.config(for: tool).commandTemplate()
        let copied = copiedCommandTool == tool
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tool.iconName)
                .foregroundStyle(tool.tintColor)
                .frame(width: 16)
            Text(tool.displayName)
                .font(.caption.bold())
                .frame(width: 48, alignment: .leading)
            Text(commandTemplate)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Button {
                copyCommandTemplate(commandTemplate, for: tool)
            } label: {
                Label(copied ? L10n.text("common.copied", fallback: "Copied") : L10n.text("common.copy", fallback: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? .green : .secondary)
            .frame(minWidth: 58, alignment: .trailing)
        }
    }

    private func copyCommandTemplate(_ commandTemplate: String, for tool: ToolType) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commandTemplate, forType: .string)
        copiedCommandTool = tool
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedCommandTool == tool {
                copiedCommandTool = nil
            }
        }
    }

    private func detectionDisplayName(for executable: String) -> String {
        if executable == "cursor-agent" { return "Cursor" }
        if executable.contains("codex") { return "Codex" }
        if executable.contains("claude") { return "Claude" }
        return executable
    }

    private var customPolicyBinding: Binding<String> {
        Binding(
            get: { vm.llmConfig.customPolicy },
            set: { vm.llmConfig.customPolicy = $0 }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { appLanguage },
            set: { appLanguage = $0 }
        )
    }

    private var executionNotificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { vm.executionNotificationSettings.isEnabled },
            set: { shouldEnable in
                notificationStatusMessage = ""

                if !shouldEnable {
                    vm.executionNotificationSettings.isEnabled = false
                    notificationStatusIsError = false
                    notificationStatusMessage = L10n.text("execution.notificationsDisabled", fallback: "Execution notifications disabled.")
                    return
                }

                isRequestingNotificationPermission = true
                Task {
                    let granted = await vm.setExecutionNotificationsEnabled(true)
                    await MainActor.run {
                        isRequestingNotificationPermission = false
                        if granted {
                            notificationStatusIsError = false
                            notificationStatusMessage = L10n.text("execution.notificationsEnabled", fallback: "Execution notifications enabled.")
                        } else {
                            notificationStatusIsError = true
                            notificationStatusMessage = L10n.text("execution.permissionDeniedSettings", fallback: "Permission denied. Enable AgentCrew in System Settings > Notifications.")
                        }
                    }
                }
            }
        )
    }

    private var notificationAuthorizationHint: String {
        switch vm.executionNotificationAuthorizationState {
        case .authorized:
            return L10n.text("execution.permissionGranted", fallback: "Notification permission is granted.")
        case .denied:
            return L10n.text("execution.permissionDeniedOpenSettings", fallback: "Notification permission is denied. Open System Settings > Notifications > AgentCrew to allow alerts.")
        case .notDetermined:
            return L10n.text("execution.permissionNotRequested", fallback: "Permission has not been requested yet.")
        }
    }

    private var trimmedCustomPolicy: String {
        vm.llmConfig.customPolicy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runDetection() async {
        isDetecting = true
        let results = await profileManager.detectEnvironment()
        withAnimation(.easeInOut(duration: 0.3)) {
            detectionResults = results
            isDetecting = false
        }
    }

    private func sendExecutionTestNotification() {
        notificationStatusMessage = ""
        isSendingNotificationTest = true

        Task {
            do {
                try await vm.sendExecutionNotificationTest()
                await MainActor.run {
                    isSendingNotificationTest = false
                    notificationStatusIsError = false
                    notificationStatusMessage = L10n.text("execution.testNotificationScheduled", fallback: "Test notification scheduled (3s). Switch to another app to verify banner delivery.")
                }
            } catch {
                await MainActor.run {
                    isSendingNotificationTest = false
                    notificationStatusIsError = true
                    notificationStatusMessage = "\(L10n.text("execution.testNotificationFailedPrefix", fallback: "Failed to send test notification: "))\(error.localizedDescription)"
                }
            }
        }
    }
}
