import Foundation

// MARK: - PromptMode

enum PromptMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case inline
    case stdin
    case argument

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inline:   "Inline ({{prompt}})"
        case .stdin:    "Stdin"
        case .argument: "Positional Argument"
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
    var interactiveExecutable: String?

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
        var result: Set<String> = [
            cursor.executable,
            codex.executable,
            claude.executable,
            planner.executable,
        ]
        for exec in [cursor.interactiveExecutable, codex.interactiveExecutable, claude.interactiveExecutable] {
            if let exec { result.insert(exec) }
        }
        return result
    }

    /// Executables to check during auto-detection.
    static let detectableExecutables: [(executable: String, profileID: String)] = [
        ("codex-internal", "internal"),
        ("claude-internal", "internal"),
        ("cursor-agent", "default"),
        ("codex", "default"),
        ("claude", "default"),
    ]
}

// MARK: - Built-in Presets

extension CLIProfile {
    static func builtInProfile(id: String) -> CLIProfile? {
        builtInProfiles.first(where: { $0.id == id })
    }

    static let `default` = CLIProfile(
        id: "default",
        name: "Default (Open Source)",
        cursor: ToolCLIConfig(
            executable: "cursor-agent",
            baseArgs: ["--trust"],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: "opus-4.6",
            interactiveExecutable: "cursor-agent"
        ),
        codex: ToolCLIConfig(
            executable: "codex",
            baseArgs: ["exec", "--sandbox", "workspace-write"],
            promptFlag: nil,
            modelFlag: "--model",
            promptMode: .argument,
            defaultModel: nil,
            interactiveExecutable: "codex"
        ),
        claude: ToolCLIConfig(
            executable: "claude",
            baseArgs: ["--print", "--permission-mode", "bypassPermissions", "--add-dir", "."],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: nil,
            interactiveExecutable: "claude"
        ),
        planner: ToolCLIConfig(
            executable: "cursor-agent",
            baseArgs: ["--trust"],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: "opus-4.6"
        )
    )

    static let `internal` = CLIProfile(
        id: "internal",
        name: "Internal",
        cursor: ToolCLIConfig(
            executable: "cursor-agent",
            baseArgs: ["--trust"],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: "opus-4.6",
            interactiveExecutable: "cursor-agent"
        ),
        codex: ToolCLIConfig(
            executable: "codex-internal",
            baseArgs: ["exec", "--sandbox", "workspace-write", "--skip-git-repo-check"],
            promptFlag: nil,
            modelFlag: "--model",
            promptMode: .argument,
            defaultModel: nil,
            interactiveExecutable: "codex-internal"
        ),
        claude: ToolCLIConfig(
            executable: "claude-internal",
            baseArgs: ["--print", "--permission-mode", "bypassPermissions", "--add-dir", "."],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: nil,
            interactiveExecutable: "claude-internal"
        ),
        planner: ToolCLIConfig(
            executable: "cursor-agent",
            baseArgs: ["--trust"],
            promptFlag: "-p",
            modelFlag: "--model",
            promptMode: .inline,
            defaultModel: "opus-4.6"
        )
    )

    static let builtInProfiles: [CLIProfile] = [.default, .internal]
}
