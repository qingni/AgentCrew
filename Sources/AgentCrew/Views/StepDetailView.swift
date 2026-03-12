import SwiftUI

struct StepDetailView: View {
    let step: PipelineStep
    let pipelineID: UUID
    @EnvironmentObject var vm: AppViewModel
    @ObservedObject private var profileManager = CLIProfileManager.shared

    @State private var name: String = ""
    @State private var selectedTool: ToolType = .codex
    @State private var modelOverride: String = ""
    @State private var command: String = ""
    @State private var prompt: String = ""
    @State private var dependsOnStepIDs: [UUID] = []
    @State private var continueOnFailure: Bool = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            if vm.isPipelineLocked(pipelineID) {
                Section {
                    Label("This pipeline has already run. Stage and step configuration is now locked.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditingLocked)

                HStack {
                    Text("Tool")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $selectedTool) {
                        ForEach(ToolType.allCases) { tool in
                            Label(tool.displayName, systemImage: tool.iconName).tag(tool)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 140)
                    .disabled(isEditingLocked)
                }

                HStack {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Leave empty for default", text: $modelOverride)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .disabled(isEditingLocked)
                }

                Toggle("Continue on failure", isOn: $continueOnFailure)
                    .disabled(isEditingLocked)

                effectiveCommandPreview
            } header: {
                HStack(spacing: 8) {
                    Text("Configuration")
                    Spacer()
                    if isDirty {
                        Text("Unsaved changes")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("Save Changes") {
                        applyChanges()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!isDirty || isEditingLocked)
                }
                .textCase(nil)
            }

            Section("Prompt") {
                TextEditor(text: $prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .disabled(isEditingLocked)
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom Command Override")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topLeading) {
                        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Leave empty to use auto-generated command")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $command)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 60)
                            .scrollContentBackground(.hidden)
                            .disabled(isEditingLocked)
                    }
                    .padding(2)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary, lineWidth: 1)
                    )

                    Text("Use `{{prompt}}` to inline the prompt. If empty, command is generated from Tool + Model + Environment.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear Custom Command") {
                            command = ""
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
            }

            Section("Run After") {
                let allSteps = vm.selectedPipeline?.allSteps.filter { $0.id != step.id } ?? []
                if allSteps.isEmpty {
                    Text("This step can run immediately. No other steps are available in this pipeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select the steps that must finish before this step can run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(allSteps) { other in
                        let isDependent = dependsOnStepIDs.contains(other.id)
                        HStack {
                            Image(systemName: isDependent ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isDependent ? .blue : .secondary)
                            Text(other.name)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggleDependency(other.id) }
                    }
                }
            }
            .disabled(isEditingLocked)
        }
        .formStyle(.grouped)
        .navigationTitle("Step Detail")
        .onAppear { loadFromStep() }
        .onChange(of: step.id) { loadFromStep() }
        .onChange(of: vm.executingPipelineID) { _, executingPipelineID in
            if executingPipelineID == pipelineID && isDirty && !vm.isPipelineLocked(pipelineID) {
                scheduleApplyChanges()
            }
        }
        .onDisappear {
            if isDirty && !vm.isPipelineLocked(pipelineID) && !vm.isPipelineExecuting(pipelineID) {
                scheduleApplyChanges()
            }
        }
    }

    // MARK: - Effective Command Preview

    @State private var showCopied = false

    @ViewBuilder
    private var effectiveCommandPreview: some View {
        let profile = profileManager.activeProfile
        let preview = resolvedEffectiveCommand(profile: profile)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Resolved Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preview, forType: .string)
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopied = false
                    }
                } label: {
                    Label(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showCopied ? .green : .secondary)
            }
            Text(preview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    // MARK: - Helpers

    private func resolvedEffectiveCommand(profile: CLIProfile) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCommand.isEmpty {
            return trimmedCommand
        }
        let model = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return selectedTool.defaultCommandTemplate(
            model: model.isEmpty ? nil : model,
            profile: profile
        )
    }

    private func loadFromStep() {
        name = step.name
        selectedTool = step.tool
        modelOverride = step.model ?? ""
        command = step.command ?? ""
        prompt = step.prompt
        dependsOnStepIDs = step.dependsOnStepIDs
        continueOnFailure = step.continueOnFailure
        showAdvanced = step.hasCustomCommand
    }

    private func applyChanges() {
        guard !vm.isPipelineLocked(pipelineID) else { return }
        guard !vm.isPipelineExecuting(pipelineID) else { return }
        var updated = step
        updated.name = name
        updated.tool = selectedTool
        let trimmedModel = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = trimmedModel.isEmpty ? nil : trimmedModel
        updated.command = sanitizedCommand(command)
        updated.prompt = prompt
        updated.dependsOnStepIDs = dependsOnStepIDs
        updated.continueOnFailure = continueOnFailure
        vm.updateStep(updated, in: pipelineID)
    }

    private func toggleDependency(_ otherID: UUID) {
        if let idx = dependsOnStepIDs.firstIndex(of: otherID) {
            dependsOnStepIDs.remove(at: idx)
        } else {
            dependsOnStepIDs.append(otherID)
        }
    }

    private func sanitizedCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .replacingOccurrences(of: "\"{{prompt}}\"", with: "{{prompt}}")
            .replacingOccurrences(of: "'{{prompt}}'", with: "{{prompt}}")
    }

    private var isDirty: Bool {
        let trimmedCommand = sanitizedCommand(command)
        let trimmedSavedCommand = step.command.flatMap { sanitizedCommand($0) }
        let trimmedModel = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedModel = step.model ?? ""

        return name != step.name
            || selectedTool != step.tool
            || trimmedModel != savedModel
            || prompt != step.prompt
            || continueOnFailure != step.continueOnFailure
            || trimmedCommand != trimmedSavedCommand
            || Set(dependsOnStepIDs) != Set(step.dependsOnStepIDs)
    }

    private func scheduleApplyChanges() {
        DispatchQueue.main.async {
            applyChanges()
        }
    }

    private var isEditingLocked: Bool {
        vm.isPipelineExecuting(pipelineID) || vm.isPipelineLocked(pipelineID)
    }
}
