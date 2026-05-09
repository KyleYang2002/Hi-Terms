import Foundation

/// One captured shell command lifecycle.
///
/// Lines refer to scroll-invariant buffer rows (i.e. ids returned by
/// `SwiftTermAdapter.scrollInvariantRow(forViewportRow:)`) so they remain
/// stable as the viewport scrolls and SwiftTerm trims scrollback.
public struct CommandRecord: Equatable, Sendable {
    public let id: UUID
    public var promptStartLine: Int?
    public var commandStartLine: Int?
    public var outputStartLine: Int?
    public var endLine: Int?
    public var exitCode: Int32?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        promptStartLine: Int? = nil,
        commandStartLine: Int? = nil,
        outputStartLine: Int? = nil,
        endLine: Int? = nil,
        exitCode: Int32? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.promptStartLine = promptStartLine
        self.commandStartLine = commandStartLine
        self.outputStartLine = outputStartLine
        self.endLine = endLine
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// Public change events emitted by `ShellIntegrationState`. Subscribers receive
/// these on whatever thread the OSC sequence was parsed on (typically the PTY
/// callback queue) — UI consumers must marshal to main themselves.
public enum ShellIntegrationChange: Sendable {
    case cwdChanged(URL?, host: String?, raw: String)
    case promptStarted(line: Int)
    case commandInputStarted(line: Int)
    case commandOutputStarted(line: Int)
    case commandFinished(record: CommandRecord)
}

/// Aggregates state derived from OSC 7 (cwd) + OSC 133 (semantic prompt
/// markers) emitted by an integrated shell rc.
///
/// Threading: writers (the OSC handler) live on the PTY parse callback;
/// readers (UI) live on main. Mutations are guarded by an `NSLock`. Callbacks
/// are invoked outside the lock so consumers may re-enter the state without
/// deadlocking.
public final class ShellIntegrationState: @unchecked Sendable {
    public private(set) var currentWorkingDirectoryURL: URL?
    public private(set) var currentWorkingDirectoryRaw: String?
    public private(set) var currentWorkingDirectoryHost: String?
    public private(set) var lastExitCode: Int32?
    public private(set) var commandHistory: [CommandRecord] = []
    public private(set) var current: CommandRecord?

    /// Fired after every applied state change. Set once from the owning
    /// adapter's init or from the UI layer; replacing it from multiple
    /// threads is the caller's responsibility.
    public var onChange: ((ShellIntegrationChange) -> Void)?

    private let lock = NSLock()
    private static let historyCap = 256

    public init() {}

    // MARK: - OSC 7 (cwd)

    /// Apply an OSC 7 payload. `raw` is the value SwiftTerm parsed into
    /// `terminal.hostCurrentDirectory` — typically `file://hostname/<path>`
    /// where the path is URL-encoded.
    public func applyCwd(raw: String) {
        let (url, host) = Self.parseFileURI(raw)
        lock.lock()
        currentWorkingDirectoryRaw = raw
        currentWorkingDirectoryURL = url
        currentWorkingDirectoryHost = host
        lock.unlock()
        onChange?(.cwdChanged(url, host: host, raw: raw))
    }

    // MARK: - OSC 133 (semantic prompt markers)

    /// OSC 133;A — prompt about to be drawn. Opens a fresh `current` record.
    public func handlePromptStart(line: Int) {
        lock.lock()
        var record = CommandRecord(startedAt: Date())
        record.promptStartLine = line
        current = record
        lock.unlock()
        onChange?(.promptStarted(line: line))
    }

    /// OSC 133;B — user input area starts (after the prompt glyph).
    public func handleCommandInputStart(line: Int) {
        lock.lock()
        if current == nil {
            current = CommandRecord(startedAt: Date())
        }
        current?.commandStartLine = line
        lock.unlock()
        onChange?(.commandInputStarted(line: line))
    }

    /// OSC 133;C — command has been submitted, output region begins.
    public func handleCommandOutputStart(line: Int) {
        lock.lock()
        if current == nil {
            current = CommandRecord(startedAt: Date())
        }
        current?.outputStartLine = line
        lock.unlock()
        onChange?(.commandOutputStarted(line: line))
    }

    /// OSC 133;D[;exit] — command finished. Closes `current`, appends to
    /// history (ring-buffer capped at `historyCap`) and clears `current`.
    public func handleCommandEnd(line: Int, exitCode: Int32?) {
        var finishedRecord: CommandRecord
        lock.lock()
        if var rec = current {
            rec.endLine = line
            rec.exitCode = exitCode
            rec.finishedAt = Date()
            finishedRecord = rec
        } else {
            // No prior A/B/C — synthesise a minimal record so consumers still
            // observe the exit. startedAt collapses onto finishedAt.
            let now = Date()
            var rec = CommandRecord(startedAt: now)
            rec.endLine = line
            rec.exitCode = exitCode
            rec.finishedAt = now
            finishedRecord = rec
        }
        commandHistory.append(finishedRecord)
        if commandHistory.count > Self.historyCap {
            commandHistory.removeFirst(commandHistory.count - Self.historyCap)
        }
        current = nil
        lastExitCode = exitCode
        lock.unlock()
        onChange?(.commandFinished(record: finishedRecord))
    }

    // MARK: - URI parsing

    /// Parse an OSC 7 `file://host/url-encoded-path` payload.
    ///
    /// - Returns: `(url, host)` on success — `url.path` is already URL-decoded
    ///   so CJK percent-escapes round-trip to their original characters.
    ///   Returns `(nil, nil)` if `raw` isn't a `file://` URL.
    static func parseFileURI(_ raw: String) -> (URL?, String?) {
        guard let comps = URLComponents(string: raw) else {
            return (nil, nil)
        }
        guard comps.scheme?.lowercased() == "file" else {
            return (nil, nil)
        }
        // `comps.path` is percent-decoded already.
        let decodedPath = comps.path
        guard !decodedPath.isEmpty else {
            return (nil, comps.host)
        }
        let url = URL(fileURLWithPath: decodedPath)
        return (url, comps.host)
    }
}
