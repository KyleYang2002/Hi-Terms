import Foundation

/// A terminal session's complete lifecycle.
///
/// V0.1 has one concrete implementation: `TerminalSession`.
/// Future versions extend via protocol (persistence, external API, multi-tab).
public protocol Session: AnyObject {
    /// Unique identifier (UUID).
    var id: SessionID { get }

    /// Current state (running or exited).
    var state: SessionState { get }

    /// Creation timestamp.
    var createdAt: Date { get }

    /// Shell path used to launch the session.
    var launchCommand: String { get }

    /// Associated terminal pipeline (owned by session).
    var pipeline: any TerminalPipeline { get }

    /// Shell integration state (OSC 7 cwd + OSC 133 prompt markers).
    /// V0.0.3 T1: surfaced through Session so downstream features (cwd-aware
    /// New Tab, command boundaries, scrollback navigation) can subscribe
    /// without depending on the concrete pipeline type.
    var shellIntegration: ShellIntegrationState { get }

    /// Start the session: activate the pipeline's data flow.
    func start() throws

    /// Stop the session: terminate PTY, clean up resources.
    func stop()

    /// Write data to PTY (user input).
    func write(data: Data)

    /// Resize terminal dimensions (V0.2 actual use, V0.1 reserves interface).
    func resize(cols: Int, rows: Int)

    /// Callback fired when state changes (e.g., running → exited).
    var onStateChanged: ((SessionState) -> Void)? { get set }
}

extension Session {
    /// Default implementation: forward to the owned pipeline. Concrete sessions
    /// only override this if they have a non-pipeline source of shell state.
    /// Keeps lightweight test mocks (and any future Session impls that simply
    /// wrap a pipeline) from having to restate the trivial passthrough.
    public var shellIntegration: ShellIntegrationState { pipeline.shellIntegration }
}
