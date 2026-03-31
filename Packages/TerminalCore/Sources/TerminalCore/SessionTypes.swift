import Foundation

/// Unique identifier for a terminal session.
/// V0.1 will add full session lifecycle management.
public typealias SessionID = UUID

/// Basic session state. V0.1 will expand to the full 7-state model
/// (started, running, awaitingInput, interrupted, completed, failed, stopped).
public enum SessionState: Sendable {
    case running
    case exited
}
