import SwiftUI

struct CLIProfileSetupView: View {
    @ObservedObject private var profileManager = CLIProfileManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var detectionResults: [CLIProfileManager.DetectionResult] = []
    @State private var recommendedProfile: CLIProfile = .default
    @State private var selectedProfileID: String = CLIProfile.default.id
    @State private var isDetecting = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detectionSection
                    profileSelectionSection
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
                Text("CLI Environment")
                    .font(.title2.bold())
                Text("Choose which CLI tools to use")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .background(.bar)
    }

    // MARK: - Detection

    private var detectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Detected Tools")
                        .font(.subheadline.bold())
                    Spacer()
                    if isDetecting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning...")
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
                                Text(result.executable)
                                    .font(.system(.caption, design: .monospaced))
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

    // MARK: - Profile Selection

    private var profileSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isDetecting {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                    Text("Recommended:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(recommendedProfile.name)
                        .font(.caption.bold())
                }
            }

            ForEach(CLIProfile.builtInProfiles, id: \.id) { profile in
                profileCard(profile)
            }
        }
    }

    private func profileCard(_ profile: CLIProfile) -> some View {
        let isSelected = selectedProfileID == profile.id
        let isRecommended = profile.id == recommendedProfile.id && !isDetecting
        return Button {
            selectedProfileID = profile.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.3))
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(isSelected ? .primary : .secondary)
                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue, in: Capsule())
                        }
                    }

                    HStack(spacing: 12) {
                        cliLabel(profile.cursor.executable, tool: .cursor)
                        cliLabel(profile.codex.executable, tool: .codex)
                        cliLabel(profile.claude.executable, tool: .claude)
                    }
                    .opacity(isSelected ? 1.0 : 0.5)
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func cliLabel(_ executable: String, tool: ToolType) -> some View {
        HStack(spacing: 3) {
            Image(systemName: tool.iconName)
                .foregroundStyle(tool.tintColor)
                .font(.caption2)
            Text(executable)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tool Summary

    private var toolSummarySection: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
            Text("You can change this later in **Settings**")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip") {
                profileManager.skipSetup()
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Continue") {
                if let profile = CLIProfile.builtInProfiles.first(where: { $0.id == selectedProfileID }) {
                    profileManager.completeSetup(with: profile)
                }
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
        let (results, recommended) = await profileManager.detectEnvironment()
        withAnimation(.easeInOut(duration: 0.3)) {
            detectionResults = results
            recommendedProfile = recommended
            selectedProfileID = recommended.id
            isDetecting = false
        }
    }
}
