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

    /// Creates a window controller with the given session and pipeline.
    ///
    /// - Parameters:
    ///   - session: The terminal session (strong reference held by this controller).
    ///   - pipeline: The concrete pipeline (passed to TerminalView for renderer access).
    public init(session: any Session, pipeline: DefaultTerminalPipeline) {
        self.session = session

        // Calculate window size from terminal dimensions and font metrics
        let font = NSFont(name: "Menlo", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let fontMetrics = FontMetrics.measure(font: font)
        let contentWidth = CGFloat(pipeline.screenBuffer.cols) * fontMetrics.cellWidth
        let contentHeight = CGFloat(pipeline.screenBuffer.rows) * fontMetrics.cellHeight
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
