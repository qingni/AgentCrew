import SwiftUI

struct StepDetailView: View {
    let step: PipelineStep
    let pipelineID: UUID
    @EnvironmentObject var vm: AppViewModel

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var prompt: String = ""
    @State private var dependsOnStepIDs: [UUID] = []
    @State private var continueOnFailure: Bool = false
    @State private var showCommandHelp = false

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

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Command")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            showCommandHelp = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Show supported command examples")
                        .popover(isPresented: $showCommandHelp, arrowEdge: .top) {
                            CommandHelpPopover()
                        }

                        Spacer()
                    }

                    ZStack(alignment: .topLeading) {
                        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("agent --trust --model opus-4.6 -p {{prompt}}")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $command)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 72)
                            .scrollContentBackground(.hidden)
                            .disabled(isEditingLocked)
                    }
                    .padding(2)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary, lineWidth: 1)
                    )

                    Text("Use `{{prompt}}` to inline the prompt. If omitted, the prompt below is sent to stdin.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle("Continue on failure", isOn: $continueOnFailure)
                    .disabled(isEditingLocked)
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

    // MARK: - Helpers

    private func loadFromStep() {
        name = step.name
        command = step.effectiveCommand
        prompt = step.prompt
        dependsOnStepIDs = step.dependsOnStepIDs
        continueOnFailure = step.continueOnFailure
    }

    private func applyChanges() {
        guard !vm.isPipelineLocked(pipelineID) else { return }
        guard !vm.isPipelineExecuting(pipelineID) else { return }
        var updated = step
        updated.name = name
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
        let sanitizedCurrentCommand = sanitizedCommand(command)
        let sanitizedSavedCommand = sanitizedCommand(step.effectiveCommand)

        return name != step.name
            || prompt != step.prompt
            || continueOnFailure != step.continueOnFailure
            || sanitizedCurrentCommand != sanitizedSavedCommand
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

private struct CommandHelpPopover: View {
    private let cursorCommands = [
        "agent --trust --model opus-4.6 -p {{prompt}}",
    ]

    private let codexCommands = [
        "codex-internal exec --sandbox workspace-write --skip-git-repo-check {{prompt}}",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Supported Commands")
                .font(.headline)

            Text("Use `{{prompt}}` to inline the prompt. If the command does not include it, the Prompt section below is sent through stdin.")
                .font(.caption)
                .foregroundStyle(.secondary)

            commandSection(title: "Cursor CLI", commands: cursorCommands)
            commandSection(title: "Codex CLI", commands: codexCommands)
        }
        .padding(16)
        .frame(width: 460)
    }

    @ViewBuilder
    private func commandSection(title: String, commands: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())

            ForEach(commands, id: \.self) { command in
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
