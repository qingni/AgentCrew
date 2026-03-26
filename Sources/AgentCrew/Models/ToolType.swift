import SwiftUI

enum ToolType: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor

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
        case .cursor: ["claude-4.6-opus-max-thinking", "gpt-5", "sonnet-4"]
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

    func defaultCommandTemplate(model: String? = nil, profile: CLIProfile) -> String {
        profile.config(for: self).commandTemplate(model: model)
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
        if lower.contains("cursor-agent")
            || lower.hasPrefix("cursor ")
            || lower.contains(" cursor ")
            || lower.hasPrefix("agent ")
            || lower.contains(" agent ")
        {
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
