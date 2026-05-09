import AppKit
import TerminalCore
import TerminalRenderer

/// Manages a single terminal window.
///
/// Window size is calculated from terminal dimensions × font cell size,
/// ensuring pixel-perfect grid alignment.
public final class TerminalWindowController: NSWindowController {
    private let session: any Session
    private var terminalView: TerminalView!
    private let baseTitle: String
    private let shellName: String
    private let homePath: String
    private let localHostNames: Set<String>

    /// Creates a window controller with the given session and pipeline.
    ///
    /// - Parameters:
    ///   - session: The terminal session (strong reference held by this controller).
    ///   - pipeline: The concrete pipeline (passed to TerminalView for renderer access).
    public init(session: any Session, pipeline: DefaultTerminalPipeline) {
        self.session = session
        self.baseTitle = "Hi-Terms"
        self.shellName = (session.launchCommand as NSString).lastPathComponent
        self.homePath = FileManager.default.homeDirectoryForCurrentUser.path
        var hosts: Set<String> = ["localhost", ""]
        hosts.insert(ProcessInfo.processInfo.hostName)
        if let local = Host.current().localizedName { hosts.insert(local) }
        for name in Host.current().names { hosts.insert(name) }
        self.localHostNames = hosts

        // Calculate window size from terminal dimensions and font metrics,
        // adding TerminalLayout.contentInset on each side so the grid does not
        // touch the window's edges.
        let font = NSFont(name: "Menlo", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let fontMetrics = FontMetrics.measure(font: font)
        let inset = TerminalLayout.contentInset
        let contentWidth = CGFloat(pipeline.screenBuffer.cols) * fontMetrics.cellWidth + 2 * inset.width
        let contentHeight = CGFloat(pipeline.screenBuffer.rows) * fontMetrics.cellHeight + 2 * inset.height
        let contentRect = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hi-Terms"
        window.center()

        super.init(window: window)

        // Create terminal view and set as content
        terminalView = TerminalView(session: session, pipeline: pipeline, frame: contentRect)
        window.contentView = terminalView
        window.makeFirstResponder(terminalView)

        // Monitor session state — close window when shell exits
        session.onStateChanged = { [weak self] state in
            if case .exited = state {
                DispatchQueue.main.async {
                    self?.window?.close()
                }
            }
        }

        // Update window title when shell integration reports a new cwd.
        session.shellIntegration.onChange = { [weak self] change in
            guard case let .cwdChanged(url, host, _) = change else { return }
            DispatchQueue.main.async {
                self?.applyWindowTitle(cwd: url, host: host)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func applyWindowTitle(cwd: URL?, host: String?) {
        guard let window else { return }
        let isRemote = host.map { !localHostNames.contains($0) } ?? false
        if let cwd {
            let path = cwd.path
            if isRemote, let host {
                window.title = "\(host):\(path) — ssh"
            } else {
                let display: String
                if path == homePath {
                    display = "~"
                } else if path.hasPrefix(homePath + "/") {
                    display = "~" + path.dropFirst(homePath.count)
                } else {
                    display = path
                }
                window.title = "\(display) — \(shellName)"
            }
        } else {
            window.title = baseTitle
        }
    }
}
