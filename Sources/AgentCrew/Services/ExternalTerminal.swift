import AppKit

enum ExternalTerminal {
    static func open(tool: ToolType, workingDirectory: String, extraArgs: [String] = []) {
        let command = tool.interactiveCommand
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
