import Foundation

/// Global registry of all active terminal sessions.
///
/// Thread-safe via GCD serial queue. Supports register, unregister, query by ID,
/// and listing all sessions.
///
/// `init()` is public to allow tests to create isolated instances.
/// Production code uses `SessionRegistry.shared`.
public final class SessionRegistry {
    public static let shared = SessionRegistry()

    private let queue = DispatchQueue(label: "com.hiterms.session-registry")
    private var sessions: [SessionID: any Session] = [:]

    public init() {}

    /// Registers a session. Overwrites if the same ID already exists.
    public func register(_ session: any Session) {
        queue.sync { sessions[session.id] = session }
    }

    /// Removes a session by ID.
    public func unregister(_ sessionID: SessionID) {
        queue.sync { _ = sessions.removeValue(forKey: sessionID) }
    }

    /// Returns all registered sessions (snapshot).
    public func allSessions() -> [any Session] {
        queue.sync { Array(sessions.values) }
    }

    /// Looks up a session by ID.
    public func session(for id: SessionID) -> (any Session)? {
        queue.sync { sessions[id] }
    }

    /// Number of registered sessions.
    public var count: Int {
        queue.sync { sessions.count }
    }
}
