import SwiftUI

struct CLIProfileSetupView: View {
    @ObservedObject private var profileManager = CLIProfileManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var detectionResults: [CLIProfileManager.DetectionResult] = []
    @State private var isDetecting = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modeSwitchSection
                    detectionSection
                    toolSummarySection
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await runDetection() }
        .onChange(of: profileManager.useInternalCommands) { _, _ in
            Task { await runDetection() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.blue.gradient)
                    .frame(width: 44, height: 44)
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("cli.environment", fallback: "CLI Environment"))
                    .font(.title2.bold())
                Text(L10n.text("cli.environmentSubtitle", fallback: "Choose a command mode for Codex and Claude"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .background(.bar)
    }

    // MARK: - Mode Switch

    private var modeSwitchSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
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
            }
            .padding(4)
        }
    }

    // MARK: - Detection

    private var detectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.text("cli.toolAvailability", fallback: "Tool Availability"))
                        .font(.subheadline.bold())
                    Spacer()
                    if isDetecting {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text("common.checking", fallback: "Checking..."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !isDetecting {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ], spacing: 8) {
                        ForEach(detectionResults, id: \.executable) { result in
                            HStack(spacing: 6) {
                                Image(systemName: result.found ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(result.found ? .green : .secondary)
                                    .font(.caption)
                                Text(detectionDisplayName(for: result.executable))
                                    .font(.caption)
                                Spacer()
                            }
                            .padding(.vertical, 4)
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
            }
            .padding(4)
        }
    }

    private func detectionDisplayName(for executable: String) -> String {
        if executable == "cursor-agent" { return "Cursor" }
        if executable.contains("codex") { return "Codex" }
        if executable.contains("claude") { return "Claude" }
        return executable
    }

    // MARK: - Tool Summary

    private var toolSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                Text(L10n.text("common.howItWorks", fallback: "How this works"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            Text(L10n.text("cli.settingAffectsCodexClaude", fallback: "This setting only changes Codex and Claude behavior."))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(L10n.text("cli.changeLaterInSettings", fallback: "You can change this later in **Settings**"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(L10n.text("common.skip", fallback: "Skip")) {
                profileManager.skipSetup()
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(L10n.text("common.continue", fallback: "Continue")) {
                profileManager.completeSetup()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDetecting)
        }
        .padding(20)
        .background(.bar)
    }

    // MARK: - Detection Logic

    private func runDetection() async {
        isDetecting = true
        let results = await profileManager.detectEnvironment()
        withAnimation(.easeInOut(duration: 0.3)) {
            detectionResults = results
            isDetecting = false
        }
    }
}
