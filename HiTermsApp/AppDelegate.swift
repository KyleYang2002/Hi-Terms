import AppKit
import os.log
import Configuration
import PTYKit
import TerminalCore
import TerminalRenderer
import TerminalUI

private let logger = Logger(subsystem: "com.hiterms.app", category: "general")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: TerminalWindowController?
    private var session: TerminalSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("HiTerms application did finish launching (v0.1.0)")

        do {
            try startTerminalSession()
        } catch {
            logger.error("Failed to start terminal session: \(error.localizedDescription)")
            showErrorAndTerminate(error: error)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Private

    private func startTerminalSession() throws {
        let config = DefaultConfig()

        // 1. Create PTY
        let ptyConfig = PTYConfiguration(
            shellPath: config.shellPath,
            initialWindowSize: (cols: UInt16(config.terminalCols), rows: UInt16(config.terminalRows)),
            terminalType: config.terminalType
        )
        let ptyProcess = try PTYProcess(configuration: ptyConfig)

        // 2. Create pipeline components
        let adapter = SwiftTermAdapter(cols: config.terminalCols, rows: config.terminalRows)
        let dirtyRegion = DirtyRegion()
        let renderCoordinator = RenderCoordinator(dirtyRegion: dirtyRegion)

        // 3. Assemble pipeline
        let pipeline = DefaultTerminalPipeline(
            ptyProcess: ptyProcess,
            adapter: adapter,
            dirtyRegion: dirtyRegion,
            renderCoordinator: renderCoordinator
        )

        // 4. Create session
        let session = TerminalSession(
            launchCommand: config.shellPath,
            pipeline: pipeline
        )

        // 5. Wire PTY exit → session state transition
        ptyProcess.exitHandler = { [weak session] code in
            session?.handleProcessExit(code: code)
        }

        // 6. Start session and register
        try session.start()
        SessionRegistry.shared.register(session)
        self.session = session

        // 7. Create window
        let windowController = TerminalWindowController(session: session, pipeline: pipeline)
        windowController.showWindow(nil)
        self.windowController = windowController

        logger.info("Terminal session started: \(session.id)")
    }

    private func showErrorAndTerminate(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to start terminal"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
