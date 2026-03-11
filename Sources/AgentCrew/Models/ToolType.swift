import SwiftUI

enum ToolType: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor

    static let defaultCursorModel = "opus-4.6"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        }
    }

    var defaultModels: [String] {
        switch self {
        case .codex: ["gpt-5-codex", "o3", "gpt-4.1"]
        case .claude: ["sonnet", "opus", "haiku"]
        case .cursor: [Self.defaultCursorModel, "gpt-5", "sonnet-4"]
        }
    }

    var iconName: String {
        switch self {
        case .codex: "terminal"
        case .claude: "brain.head.profile"
        case .cursor: "cursorarrow.rays"
        }
    }

    var tintColor: Color {
        switch self {
        case .codex: .green
        case .claude: .orange
        case .cursor: .blue
        }
    }

    var interactiveCommand: String {
        switch self {
        case .codex: "codex-internal"
        case .claude: "claude-internal"
        case .cursor: "agent"
        }
    }

    var supportsInteractive: Bool { true }

    func defaultCommandTemplate(model: String? = nil) -> String {
        switch self {
        case .codex:
            var command = "codex-internal exec --sandbox workspace-write --skip-git-repo-check"
            if let model, !model.isEmpty {
                command += " --model \(model)"
            }
            return command + " {{prompt}}"
        case .claude:
            var command = "claude --print --permission-mode bypassPermissions --add-dir ."
            if let model, !model.isEmpty {
                command += " --model \(model)"
            }
            return command
        case .cursor:
            let resolvedModel: String
            if let model, !model.isEmpty {
                resolvedModel = model
            } else {
                resolvedModel = Self.defaultCursorModel
            }
            return "agent --trust --model \(resolvedModel) -p {{prompt}}"
        }
    }

    /// Resolve tool type from a keyword string (used by AI planner output).
    static func fromKeyword(_ keyword: String) -> ToolType {
        let lower = keyword.lowercased()
        if lower.contains("cursor") || lower.contains("agent") { return .cursor }
        if lower.contains("codex") || lower.contains("openai") { return .codex }
        if lower.contains("claude") { return .claude }
        return .codex
    }

    static func detected(fromCommandLine commandLine: String) -> ToolType? {
        let lower = commandLine.lowercased()
        if lower.contains("cursor-agent") || lower.hasPrefix("agent ") || lower.contains(" agent ") {
            return .cursor
        }
        if lower.contains("codex") {
            return .codex
        }
        if lower.contains("claude") {
            return .claude
        }
        return nil
    }
}
