import Foundation
import os.log

/// V0.1's concrete Session implementation.
///
/// Owns a `TerminalPipeline` (injected at init) and drives its lifecycle.
/// The pipeline is created externally (by AppDelegate) and injected to avoid
/// TerminalCore depending on TerminalUI.
///
/// PTY exit notification flows via `handleProcessExit(code:)`, which the caller
/// wires to `PTYProcess.exitHandler`.
public final class TerminalSession: Session {
    public let id: SessionID = UUID()
    public private(set) var state: SessionState = .running
    public let createdAt: Date = Date()
    public let launchCommand: String
    public let pipeline: any TerminalPipeline
    public var onStateChanged: ((SessionState) -> Void)?

    /// Guards against double-start.
    private var started = false

    // MARK: - Init

    /// Creates a session with an injected pipeline.
    ///
    /// - Parameters:
    ///   - launchCommand: The shell path (for display/logging).
    ///   - pipeline: A fully-wired TerminalPipeline instance.
    public init(launchCommand: String, pipeline: any TerminalPipeline) {
        self.launchCommand = launchCommand
        self.pipeline = pipeline
        TerminalLog.session.info("Session created: \(self.id)")
    }

    // MARK: - Session Protocol

    /// Activates the pipeline's data flow. Idempotent (second call is a no-op).
    public func start() throws {
        guard !started else { return }
        started = true
        pipeline.start()
        TerminalLog.session.info("Session started: \(self.id)")
    }

    /// Stops the session and transitions to `.exited(code: 0)`.
    /// No-op if already exited.
    public func stop() {
        guard case .running = state else { return }
        pipeline.stop()
        state = .exited(code: 0)
        onStateChanged?(state)
        TerminalLog.session.info("Session stopped: \(self.id)")
    }

    /// Writes user input data to the PTY via the pipeline.
    public func write(data: Data) {
        pipeline.write(data: data)
    }

    /// Resizes the terminal. V0.1 fixed window; V0.2 will use this.
    public func resize(cols: Int, rows: Int) {
        pipeline.resize(cols: cols, rows: rows)
    }

    // MARK: - Exit Handler

    /// Called by the external PTY exit handler wiring.
    ///
    /// AppDelegate wires: `ptyProcess.exitHandler = { session.handleProcessExit(code:) }`
    /// This transitions the session state and fires `onStateChanged`.
    public func handleProcessExit(code: Int32) {
        guard case .running = state else { return }
        state = .exited(code: code)
        onStateChanged?(state)
        TerminalLog.session.info("Session process exited: \(self.id), code=\(code)")
    }

    deinit {
        if case .running = state {
            pipeline.stop()
            TerminalLog.session.info("Session deallocated while running, stopped pipeline: \(self.id)")
        }
    }
}
