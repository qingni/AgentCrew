import SwiftUI
import SwiftTerm

struct TerminalWrapper: NSViewRepresentable {
    let executable: String
    let arguments: [String]
    let workingDirectory: String
    var initialCommand: String?
    var onProcessExit: ((Int32?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessExit: onProcessExit)
    }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv

        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let process = LocalProcess(delegate: context.coordinator)
        context.coordinator.process = process

        process.startProcess(
            executable: executable,
            args: arguments,
            environment: env,
            execName: nil,
            currentDirectory: workingDirectory
        )

        if let cmd = initialCommand {
            let cmdData = Array((cmd + "\n").utf8)
            context.coordinator.pendingCommand = cmdData
        }

        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.process?.terminate()
    }

    final class Coordinator: NSObject, LocalProcessDelegate, TerminalViewDelegate {
        weak var terminalView: TerminalView?
        var process: LocalProcess?
        var onProcessExit: ((Int32?) -> Void)?
        var pendingCommand: [UInt8]?
        private var shellReady = false

        init(onProcessExit: ((Int32?) -> Void)?) {
            self.onProcessExit = onProcessExit
        }

        // MARK: - LocalProcessDelegate

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            DispatchQueue.main.async { [weak self] in
                self?.onProcessExit?(exitCode)
            }
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            terminalView?.feed(byteArray: slice)

            if !shellReady, let cmd = pendingCommand {
                shellReady = true
                pendingCommand = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.process?.send(data: cmd[...])
                }
            }
        }

        func getWindowSize() -> winsize {
            guard let tv = terminalView else {
                return winsize(ws_row: 25, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            }
            let terminal = tv.getTerminal()
            let rows = max(terminal.rows, 1)
            let cols = max(terminal.cols, 1)
            return winsize(
                ws_row: UInt16(rows),
                ws_col: UInt16(cols),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            process?.send(data: data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            guard let fd = process?.childfd, fd != -1 else { return }
            var size = winsize(
                ws_row: UInt16(newRows),
                ws_col: UInt16(newCols),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = ioctl(fd, TIOCSWINSZ, &size)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }
        func bell(source: TerminalView) { NSSound.beep() }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
