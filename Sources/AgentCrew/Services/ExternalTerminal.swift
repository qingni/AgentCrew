import AppKit

enum ExternalTerminal {
    @MainActor
    static func open(tool: ToolType, workingDirectory: String, extraArgs: [String] = []) {
        let profile = CLIProfileManager.shared.activeProfile
        let command = tool.interactiveCommand(profile: profile)
        let args = extraArgs.isEmpty ? "" : " " + extraArgs.joined(separator: " ")

        let escapedDir = workingDirectory.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedCmd = (command + args)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            activate
            do script "cd \"\(escapedDir)\" && \(escapedCmd)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}
