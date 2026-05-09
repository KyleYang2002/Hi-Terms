import AppKit
import os.log
import UserNotifications
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
    private var bellCoordinator: BellCoordinator?
    private let notificationDelegate = BellNotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("HiTerms application did finish launching (v0.0.5)")

        installMainMenu()
        UNUserNotificationCenter.current().delegate = notificationDelegate

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

    // MARK: - Menu

    /// Builds the minimum App + Edit menu so Cmd+C / Cmd+V / Cmd+A reach the
    /// first responder via the standard responder chain. This is required for
    /// `TerminalView.copy(_:)` and `paste(_:)` to fire on shortcut.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu (anchored under the process name)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let hideItem = NSMenuItem(title: "Hide \(appName)",
                                  action: #selector(NSApplication.hide(_:)),
                                  keyEquivalent: "h")
        appMenu.addItem(hideItem)
        let hideOthersItem = NSMenuItem(title: "Hide Others",
                                        action: #selector(NSApplication.hideOtherApplications(_:)),
                                        keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — Copy/Paste/Select All flow via the responder chain to
        // TerminalView. `NSText.copy(_:)` and `NSText.paste(_:)` dispatch to
        // the matching `@objc` methods on whatever first responder owns them.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy",
                                    action: #selector(NSText.copy(_:)),
                                    keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",
                                    action: #selector(NSText.paste(_:)),
                                    keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All",
                                    action: #selector(NSText.selectAll(_:)),
                                    keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Private

    private func startTerminalSession() throws {
        let config: AppConfig = UserDefaultsConfig()

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
        let windowController = TerminalWindowController(
            session: session,
            pipeline: pipeline,
            appConfig: config
        )
        windowController.showWindow(nil)
        self.windowController = windowController

        // 8. Wire BEL handling. The coordinator must outlive `pipeline`, which
        //    holds it as a weak handler. The window/view references are weak
        //    inside the coordinator so we don't fight the WindowController for
        //    ownership of either.
        if let window = windowController.window,
           let view = window.contentView as? TerminalView {
            let bell = BellCoordinator(config: config, window: window, view: view)
            pipeline.bellHandler = bell
            self.bellCoordinator = bell
        }

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

/// Foreground-presentation policy for BEL notifications: never show banners
/// while Hi-Terms is the active app — `view.flashBell()` already provides the
/// in-window cue, so duplicating it as a banner would be noisy.
@MainActor
private final class BellNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
