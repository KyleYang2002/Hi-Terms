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

/// Render-side projection of a single command's lifecycle, derived from
/// `CommandRecord`. Row indices are scroll-invariant (same id-space as
/// `CommandRecord`) so the renderer / UI layer can clip them to the current
/// viewport via the adapter's `topScrollInvariantRow`.
///
/// Conventions:
/// - `promptRows` includes every line the prompt itself occupies (single-line
///   prompts collapse to a single row).
/// - `outputRows` covers every line of the command's output **excluding** the
///   row where OSC 133;D was emitted (that line typically holds the *next*
///   prompt). For a still-running command the upper bound is `Int.max`,
///   meaning "open-ended down to the bottom of the buffer at render time".
/// - `nil` for either range means there is nothing to paint for that band
///   (e.g. a no-output command, or a prompt that hasn't been seen yet).
public struct CommandBand: Equatable, Sendable {
    public enum Status: Sendable, Equatable {
        case running
        case success
        case failure(exitCode: Int32)
    }

    public let id: UUID
    public let promptRows: ClosedRange<Int>?
    public let outputRows: ClosedRange<Int>?
    public let status: Status

    public init(
        id: UUID,
        promptRows: ClosedRange<Int>?,
        outputRows: ClosedRange<Int>?,
        status: Status
    ) {
        self.id = id
        self.promptRows = promptRows
        self.outputRows = outputRows
        self.status = status
    }
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

    // MARK: - CommandBand projection

    /// Projects `commandHistory` + `current` into render-friendly bands.
    ///
    /// Pure derivation — no state added. The renderer calls this on every
    /// markers-changed publish; cost is O(n) over the ≤256-record ring.
    public func bands() -> [CommandBand] {
        lock.lock()
        let history = commandHistory
        let cur = current
        lock.unlock()
        var result: [CommandBand] = []
        result.reserveCapacity(history.count + 1)
        for record in history {
            result.append(Self.band(from: record, isCurrent: false))
        }
        if let cur {
            result.append(Self.band(from: cur, isCurrent: true))
        }
        return result
    }

    /// Builds a `CommandBand` from a single record. `isCurrent == true` means
    /// the record belongs to `current` (still running): even if `endLine` is
    /// somehow set we still classify as `.running` because the shell hasn't
    /// emitted the closing OSC 133;D yet.
    private static func band(from record: CommandRecord, isCurrent: Bool) -> CommandBand {
        let status: CommandBand.Status
        if isCurrent || record.endLine == nil {
            status = .running
        } else if let exit = record.exitCode, exit != 0 {
            status = .failure(exitCode: exit)
        } else {
            status = .success
        }

        let promptRows: ClosedRange<Int>? = {
            guard let p = record.promptStartLine else { return nil }
            // Upper bound = first line that is NOT part of the prompt − 1.
            // commandStartLine (B) is the first preferred boundary; fall back
            // to outputStartLine (C) or endLine (D) if B was skipped.
            if let next = record.commandStartLine ?? record.outputStartLine ?? record.endLine,
               next - 1 >= p {
                return p...(next - 1)
            }
            // No subsequent marker → prompt is at least the row where A landed.
            return p...p
        }()

        let outputRows: ClosedRange<Int>? = {
            guard let start = record.outputStartLine else { return nil }
            // For a still-running command, `endLine` is nil → output extends
            // open-ended down to the buffer bottom at render time. We encode
            // that as `Int.max` and let the publisher clip against viewport.
            let end: Int
            if let e = record.endLine {
                // The D row itself usually holds the next prompt, so subtract 1.
                end = e - 1
            } else {
                end = Int.max
            }
            guard end >= start else { return nil }
            return start...end
        }()

        return CommandBand(
            id: record.id,
            promptRows: promptRows,
            outputRows: outputRows,
            status: status
        )
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
