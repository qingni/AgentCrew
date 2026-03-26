import Foundation

// MARK: - PromptMode

enum PromptMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case inline
    case stdin
    case argument

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inline:   L10n.text("cli.promptMode.inline", fallback: "Inline ({{prompt}})")
        case .stdin:    L10n.text("cli.promptMode.stdin", fallback: "Stdin")
        case .argument: L10n.text("cli.promptMode.argument", fallback: "Positional Argument")
        }
    }
}

// MARK: - ToolCLIConfig

struct ToolCLIConfig: Codable, Sendable, Equatable {
    var executable: String
    var baseArgs: [String]
    var promptFlag: String?
    var modelFlag: String
    var promptMode: PromptMode
    var defaultModel: String?

    func buildArguments(prompt: String, model: String?, workingDirectory: String?) -> [String] {
        var args = resolvedBaseArgs(workingDirectory: workingDirectory)
        let resolvedModel = model ?? defaultModel
        if let resolvedModel, !resolvedModel.isEmpty {
            args += [modelFlag, resolvedModel]
        }
        switch promptMode {
        case .inline:
            if let flag = promptFlag {
                args += [flag, prompt]
            } else {
                args.append(prompt)
            }
        case .argument:
            if !prompt.isEmpty {
                args.append(prompt)
            }
        case .stdin:
            break
        }
        return args
    }

    func commandTemplate(model: String? = nil) -> String {
        var parts = [executable] + baseArgs
        let resolvedModel = model ?? defaultModel
        if let resolvedModel, !resolvedModel.isEmpty {
            parts += [modelFlag, resolvedModel]
        }
        switch promptMode {
        case .inline:
            if let flag = promptFlag {
                parts += [flag, "{{prompt}}"]
            } else {
                parts.append("{{prompt}}")
            }
        case .argument:
            parts.append("{{prompt}}")
        case .stdin:
            break
        }
        return parts.joined(separator: " ")
    }

    private func resolvedBaseArgs(workingDirectory: String?) -> [String] {
        guard let dir = workingDirectory else { return baseArgs }
        return baseArgs.map { $0 == "." ? dir : $0 }
    }
}

// MARK: - CLIProfile

struct CLIProfile: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var cursor: ToolCLIConfig
    var codex: ToolCLIConfig
    var claude: ToolCLIConfig
    var planner: ToolCLIConfig

    func config(for tool: ToolType) -> ToolCLIConfig {
        switch tool {
        case .cursor: cursor
        case .codex:  codex
        case .claude: claude
        }
    }

    var allExecutables: Set<String> {
        Set([
            cursor.executable,
            codex.executable,
            claude.executable,
            planner.executable,
        ])
    }

    /// Executables to check during auto-detection.
    /// Cursor is always `cursor-agent`; Codex/Claude switch by mode.
    static func detectableExecutables(useInternalCommands: Bool) -> [String] {
        if useInternalCommands {
            return ["cursor-agent", "codex-internal", "claude-internal"]
        }
        return ["cursor-agent", "codex", "claude"]
    }
}

// MARK: - Built-in Presets

extension CLIProfile {
    static func profile(useInternalCommands: Bool) -> CLIProfile {
        useInternalCommands ? .internal : .default
    }

    static func builtInProfile(id: String) -> CLIProfile? {
        builtInProfiles.first(where: { $0.id == id })
    }

    static let `default` = CLIProfile(
        id: "default",
        name: L10n.text("cli.profile.default", fallback: "Default (Open Source)"),
        cursor: ToolCLIConfig(
            executable: "cursor-agent",
            baseArgs: ["--trust"],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: "claude-4.6-opus-max-thinking"
        ),
        codex: ToolCLIConfig(
            executable: "codex",
            baseArgs: ["exec", "--sandbox", "workspace-write"],
            promptFlag: nil,
            modelFlag: "--model",
            promptMode: .argument,
            defaultModel: nil
        ),
        claude: ToolCLIConfig(
            executable: "claude",
            baseArgs: ["--print", "--permission-mode", "bypassPermissions", "--add-dir", "."],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: nil
        ),
        planner: ToolCLIConfig(
            executable: "cursor-agent",
            baseArgs: ["--trust"],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: "claude-4.6-opus-max-thinking"
        )
    )

    static let `internal` = CLIProfile(
        id: "internal",
        name: L10n.text("cli.profile.internal", fallback: "Internal"),
        cursor: ToolCLIConfig(
            executable: "cursor-agent",
            baseArgs: ["--trust"],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: "claude-4.6-opus-max-thinking"
        ),
        codex: ToolCLIConfig(
            executable: "codex-internal",
            baseArgs: ["exec", "--sandbox", "workspace-write", "--skip-git-repo-check"],
            promptFlag: nil,
            modelFlag: "--model",
            promptMode: .argument,
            defaultModel: nil
        ),
        claude: ToolCLIConfig(
            executable: "claude-internal",
            baseArgs: ["--print", "--permission-mode", "bypassPermissions", "--add-dir", "."],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: nil
        ),
        planner: ToolCLIConfig(
            executable: "cursor-agent",
            baseArgs: ["--trust"],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: "claude-4.6-opus-max-thinking"
        )
    )

    static let builtInProfiles: [CLIProfile] = [.default, .internal]
}
