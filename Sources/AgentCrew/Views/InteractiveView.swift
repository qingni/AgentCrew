import SwiftUI

struct InteractiveView: View {
    @ObservedObject private var profileManager = CLIProfileManager.shared
    @State private var selectedTool: ToolType = .claude
    @State private var workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var sessionActive = false
    @State private var sessionID = UUID()
    @State private var processExited = false
    @State private var exitCode: Int32?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if sessionActive {
                terminalArea
            } else {
                launcherArea
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $selectedTool) {
                ForEach(ToolType.allCases) { tool in
                    Label(tool.displayName, systemImage: tool.iconName).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Spacer()

            if sessionActive {
                statusBadge
                Button("Stop") {
                    stopSession()
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button("Restart") {
                    restartSession()
                }
                .buttonStyle(.bordered)
            }

            Button {
                ExternalTerminal.open(tool: selectedTool, workingDirectory: workingDirectory)
            } label: {
                Label("External Terminal", systemImage: "rectangle.on.rectangle.angled")
            }
            .buttonStyle(.bordered)
            .help("Open in system Terminal.app")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if processExited {
            let isSuccess = exitCode == 0
            HStack(spacing: 4) {
                Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                Text("Exited (\(exitCode.map(String.init) ?? "?"))")
            }
            .font(.caption)
            .foregroundStyle(isSuccess ? .green : .red)
        } else {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Running")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Launcher

    private var launcherArea: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Interactive Session")
                .font(.title2.bold())

            Text("Launch \(selectedTool.displayName) CLI in interactive mode.\nThe terminal runs directly inside the app with full PTY support.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        TextField("Working Directory", text: $workingDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse") { browseFolder() }
                            .controlSize(.small)
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: 500)

            HStack(spacing: 12) {
                Button {
                    startSession()
                } label: {
                    Label("Start Session", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    ExternalTerminal.open(tool: selectedTool, workingDirectory: workingDirectory)
                } label: {
                    Label("Open in Terminal.app", systemImage: "rectangle.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            toolInfoCard
            Spacer()
        }
        .padding()
    }

    private var toolInfoCard: some View {
        GroupBox {
            HStack(spacing: 16) {
                ForEach(ToolType.allCases) { tool in
                    VStack(spacing: 6) {
                        Image(systemName: tool.iconName)
                            .font(.title2)
                            .foregroundStyle(tool == selectedTool ? tool.tintColor : .secondary)
                        Text(tool.displayName)
                            .font(.caption.bold())
                            .foregroundStyle(tool == selectedTool ? .primary : .secondary)
                        Text(tool.interactiveCommand(profile: profileManager.activeProfile))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        tool == selectedTool
                            ? RoundedRectangle(cornerRadius: 8).fill(tool.tintColor.opacity(0.1))
                            : nil
                    )
                    .onTapGesture { selectedTool = tool }
                }
            }
            .padding(4)
        }
        .frame(maxWidth: 500)
    }

    // MARK: - Terminal

    private var terminalArea: some View {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return TerminalWrapper(
            executable: shell,
            arguments: ["-l"],
            workingDirectory: workingDirectory,
            initialCommand: selectedTool.interactiveCommand(profile: profileManager.activeProfile),
            onProcessExit: { code in
                processExited = true
                exitCode = code
            }
        )
        .id(sessionID)
    }

    // MARK: - Actions

    private func startSession() {
        processExited = false
        exitCode = nil
        sessionID = UUID()
        sessionActive = true
    }

    private func stopSession() {
        sessionActive = false
        processExited = false
        exitCode = nil
    }

    private func restartSession() {
        sessionActive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            startSession()
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
}
