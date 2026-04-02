import Foundation

/// Unique identifier for a terminal session.
/// V0.1 will add full session lifecycle management.
public typealias SessionID = UUID

/// Basic session state.
/// V0.1 expands to running/exited(code:). Full 7-state model in V0.7.
public enum SessionState: Sendable {
    case running
    case exited
}
