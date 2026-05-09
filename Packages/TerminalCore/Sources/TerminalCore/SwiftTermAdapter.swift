import Foundation
@preconcurrency import SwiftTerm

/// Wraps SwiftTerm's `Terminal` as a `TerminalParser` implementation.
///
/// Strategy B: SwiftTerm owns the terminal state (buffer, cursor, attributes).
/// Hi-Terms reads cell data from SwiftTerm's buffer for rendering via snapshots.
public final class SwiftTermAdapter: TerminalParser {
    public weak var delegate: TerminalParserDelegate?

    /// Called when SwiftTerm generates response data (e.g., DA reply).
    public var sendHandler: ((Data) -> Void)?

    /// Called when SwiftTerm reports a changed row range. Used by DirtyRegion for incremental rendering.
    public var rangeChangedHandler: ((Int, Int) -> Void)?

    /// The underlying SwiftTerm terminal instance.
    public let terminal: Terminal
    private let delegateAdapter: SwiftTermDelegateAdapter

    /// Shell integration state aggregated from OSC 7 (cwd) and OSC 133
    /// (semantic prompt markers). Always non-nil; populated only when an
    /// integrated shell rc actually emits the sequences. V0.0.3 T1.
    public let shellIntegration: ShellIntegrationState = ShellIntegrationState()

    /// Tracks DECTCEM cursor visibility (`?25h` / `?25l`). SwiftTerm keeps the
    /// authoritative `cursorHidden` flag internal, so we mirror it here from
    /// the `showCursor`/`hideCursor` delegate callbacks and surface it via
    /// `createSnapshot()`.
    private var cursorVisible: Bool = true

    public init(cols: Int = 80, rows: Int = 25) {
        self.delegateAdapter = SwiftTermDelegateAdapter()
        self.terminal = Terminal(delegate: delegateAdapter, options: TerminalOptions(cols: cols, rows: rows))
        delegateAdapter.onSendData = { [weak self] data in
            self?.sendHandler?(data)
        }
        // DECSCUSR (CSI Sp SP t) lands here. The new style is reflected on
        // `terminal.options.cursorStyle`, but the writer also gets a callback
        // so the next snapshot can be requested (the bytes that triggered the
        // change may not include any visible glyphs, so `getUpdateRange` could
        // skip the cursor row otherwise).
        delegateAdapter.onCursorStyleChanged = { [weak self] _ in
            guard let self else { return }
            self.delegate?.parser(self, didReceiveAction: .bufferUpdated)
            // Mark the current cursor row as dirty so the renderer rebuilds the
            // cursor layer with the new style on the next frame.
            let y = self.terminal.buffer.y
            self.rangeChangedHandler?(y, y)
        }
        // DECTCEM `?25h` / `?25l` arrive via showCursor/hideCursor delegate calls.
        delegateAdapter.onCursorShown = { [weak self] in
            self?.setCursorVisible(true)
        }
        delegateAdapter.onCursorHidden = { [weak self] in
            self?.setCursorVisible(false)
        }
        delegateAdapter.onBell = { [weak self] in
            self?.handleBell()
        }
        // OSC 7 (cwd). SwiftTerm parses the payload, fills
        // `terminal.hostCurrentDirectory`, then calls
        // `hostCurrentDirectoryUpdated`. We only mirror the latter.
        delegateAdapter.onHostCwdChanged = { [weak self] in
            self?.handleCwdChanged()
        }
        // OSC 133 (FinalTerm semantic prompts). SwiftTerm has no built-in
        // handler for code 133; the closure is invoked with the raw payload
        // bytes between `\e]133;` and the terminating ST/BEL.
        terminal.registerOscHandler(code: 133) { [weak self] payload in
            self?.handleOSC133(payload: payload)
        }
    }

    // MARK: - Shell integration (OSC 7 + 133)
    //
    // NOTE: SwiftTerm gates OSC 7/6 behind `TerminalDelegate.isProcessTrusted`.
    // The default protocol extension returns `true`, and SwiftTermDelegateAdapter
    // intentionally does NOT override it — overriding to `false` would silently
    // swallow OSC 7 and break shell integration. If a future reviewer adds an
    // override here, also update the cwd path to compensate.
    private func handleCwdChanged() {
        if let raw = terminal.hostCurrentDirectory {
            shellIntegration.applyCwd(raw: raw)
        }
    }

    private func handleOSC133(payload: ArraySlice<UInt8>) {
        guard let text = String(bytes: payload, encoding: .utf8), !text.isEmpty else {
            return
        }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard let kindChar = parts.first?.first else { return }
        let line = scrollInvariantRow(forViewportRow: terminal.buffer.y)
        switch kindChar {
        case "A":
            shellIntegration.handlePromptStart(line: line)
        case "B":
            shellIntegration.handleCommandInputStart(line: line)
        case "C":
            shellIntegration.handleCommandOutputStart(line: line)
        case "D":
            // OSC 133 ; D ; <exit>  — exit code optional.
            var exit: Int32? = nil
            if parts.count >= 2 {
                exit = Int32(parts[1])
            }
            shellIntegration.handleCommandEnd(line: line, exitCode: exit)
        default:
            // Unknown subcommand; per FinalTerm spec we ignore silently so
            // future extensions don't crash older clients.
            break
        }
    }

    /// Updates the mirrored DECTCEM visibility flag and marks the cursor row dirty.
    private func setCursorVisible(_ v: Bool) {
        cursorVisible = v
        let y = terminal.buffer.y
        rangeChangedHandler?(y, y)
        delegate?.parser(self, didReceiveAction: .bufferUpdated)
    }

    /// Forwards a SwiftTerm BEL event as a `.bell` parser action so higher
    /// layers (Wave1-C BellHandler) can decide on audible/visual feedback.
    private func handleBell() {
        delegate?.parser(self, didReceiveAction: .bell)
    }

    public func parse(data: Data) {
        let bytes = [UInt8](data)
        terminal.feed(byteArray: bytes)

        // DECSTR (\e[!p) 软复位时 SwiftTerm 直接改 cursorHidden=false 但不发 delegate 回调，
        // 这里手动同步以避免状态漂移。RIS (\ec) SwiftTerm 显式保留旧值，无需处理。
        if data.range(of: Data([0x1B, 0x5B, 0x21, 0x70])) != nil {
            cursorVisible = true
            let y = terminal.buffer.y
            rangeChangedHandler?(y, y)
        }

        if let range = terminal.getUpdateRange() {
            terminal.clearUpdateRange()
            delegate?.parser(self, didReceiveAction: .bufferUpdated)
            rangeChangedHandler?(range.startY, range.endY)
        }
    }

    /// Reads a cell from SwiftTerm's buffer, bridging to Hi-Terms Cell type.
    public func getCell(col: Int, row: Int) -> Cell {
        guard let line = terminal.getLine(row: row), col < line.count else { return .empty }
        let cd = line[col]
        return Cell(
            character: cd.getCharacter(),
            attributes: mapAttributes(cd.attribute),
            width: cd.width,
            hyperlinkURL: hyperlinkURL(from: cd)
        )
    }

    /// Creates a ScreenBuffer snapshot from the current SwiftTerm state.
    ///
    /// - Parameter scrollbackOffset: Number of rows to scroll back from the current viewport.
    ///   When 0 (default), returns the current viewport. When > 0, shows historical lines.
    public func createSnapshot(scrollbackOffset: Int = 0) -> ScreenBufferSnapshot {
        let rows = terminal.rows
        let cols = terminal.cols
        var cells = [[Cell]]()
        cells.reserveCapacity(rows)

        // Clamp scrollback offset to available history
        let maxScrollback = terminal.buffer.yDisp
        let effectiveOffset = max(0, min(scrollbackOffset, maxScrollback))

        if effectiveOffset == 0 {
            // Current viewport — use getLine for best compatibility
            for row in 0..<rows {
                cells.append(readLine(row: row, cols: cols, useScrollInvariant: false, scrollInvariantRow: 0))
            }
        } else {
            // Scrollback mode — use getScrollInvariantLine
            let startLine = terminal.buffer.yDisp - effectiveOffset
            for row in 0..<rows {
                cells.append(readLine(row: row, cols: cols, useScrollInvariant: true, scrollInvariantRow: startLine + row))
            }
        }

        return ScreenBufferSnapshot(
            cells: cells,
            cursor: CursorState(
                row: terminal.buffer.y,
                col: terminal.buffer.x,
                style: mapCursorStyle(terminal.options.cursorStyle),
                // Hide cursor in scrollback mode AND when DECTCEM has hidden it.
                visible: (effectiveOffset == 0) && self.cursorVisible
            ),
            rows: rows,
            cols: cols
        )
    }

    /// Maps SwiftTerm's `CursorStyle` (which encodes both shape and blink) to
    /// Hi-Terms' `CursorStyle`.
    private func mapCursorStyle(_ style: SwiftTerm.CursorStyle) -> TerminalCore.CursorStyle {
        switch style {
        case .blinkBlock:     return .blinkingBlock
        case .steadyBlock:    return .block
        case .blinkUnderline: return .blinkingUnderline
        case .steadyUnderline:return .underline
        case .blinkBar:       return .blinkingBar
        case .steadyBar:      return .bar
        }
    }

    /// Reads a single line of cells from the terminal buffer.
    private func readLine(row: Int, cols: Int, useScrollInvariant: Bool, scrollInvariantRow: Int) -> [Cell] {
        let line: BufferLine?
        if useScrollInvariant {
            line = terminal.getScrollInvariantLine(row: scrollInvariantRow)
        } else {
            line = terminal.getLine(row: row)
        }
        guard let line = line else {
            return Array(repeating: .empty, count: cols)
        }
        var rowCells = [Cell]()
        rowCells.reserveCapacity(cols)
        for col in 0..<cols {
            if col < line.count {
                let cd = line[col]
                rowCells.append(Cell(
                    character: cd.getCharacter(),
                    attributes: mapAttributes(cd.attribute),
                    width: cd.width,
                    hyperlinkURL: hyperlinkURL(from: cd)
                ))
            } else {
                rowCells.append(.empty)
            }
        }
        return rowCells
    }

    /// Extracts the OSC 8 hyperlink URL from a SwiftTerm `CharData`, if any.
    ///
    /// SwiftTerm registers OSC 8 internally (see SwiftTerm `EscapeSequenceParser`
    /// dispatch to `Terminal.oscHyperlink`) and stores the **raw payload between
    /// `OSC 8;` and the terminator** as the per-cell payload — that is the full
    /// `params;URI` body, not the URI alone. We must NOT re-register an OSC 8
    /// handler here (it would shadow SwiftTerm's built-in handler).
    ///
    /// Per the OSC 8 spec, `params` (e.g. `id=foo:bar=baz`) and `URI` are
    /// separated by the first `;`. We split on that and return the trailing
    /// URI portion. An empty URI (caused by the closing `OSC 8;;ST` accidentally
    /// being applied to a cell) returns nil.
    private func hyperlinkURL(from cd: CharData) -> String? {
        guard cd.hasPayload, let raw = cd.getPayload() as? String else { return nil }
        guard let semi = raw.firstIndex(of: ";") else {
            // Malformed payload (no `;` at all): treat as the URI itself.
            return raw.isEmpty ? nil : raw
        }
        let uri = String(raw[raw.index(after: semi)...])
        return uri.isEmpty ? nil : uri
    }

    private func mapAttributes(_ attr: Attribute) -> TextAttributes {
        TextAttributes(
            bold: attr.style.contains(.bold),
            italic: attr.style.contains(.italic),
            underline: attr.style.contains(.underline),
            strikethrough: attr.style.contains(.crossedOut),
            inverse: attr.style.contains(.inverse),
            invisible: attr.style.contains(.invisible),
            dim: attr.style.contains(.dim),
            foregroundColor: mapColor(attr.fg),
            backgroundColor: mapColor(attr.bg)
        )
    }

    private func mapColor(_ color: Attribute.Color) -> TerminalColor {
        switch color {
        case .defaultColor:
            return .default
        case .defaultInvertedColor:
            return .defaultInverted
        case .ansi256(let code):
            return .ansi256(code: code)
        case .trueColor(let r, let g, let b):
            return .trueColor(r: r, g: g, b: b)
        }
    }

    // MARK: - Scroll-invariant row helpers
    //
    // These read SwiftTerm state without taking any extra lock; they have the
    // same threading constraints as `createSnapshot` (i.e. callers must not
    // race with `parse`). They exist so T1 (Shell Integration) and T2
    // (selection row anchoring) can share a single notion of "which absolute
    // buffer row is at viewport top right now" without each re-deriving it
    // from `terminal.buffer.yDisp`.

    /// Buffer index of the row currently at the top of the viewport.
    ///
    /// Equivalent to `terminal.buffer.yDisp`. Combined with a viewport-relative
    /// row index this yields a stable "scroll-invariant" row id: as long as
    /// SwiftTerm's scrollback hasn't evicted the line, the id stays valid
    /// across subsequent scrolls.
    public var topScrollInvariantRow: Int { terminal.buffer.yDisp }

    /// Buffer index of the row currently at the bottom of the viewport (inclusive).
    public var bottomScrollInvariantRow: Int {
        terminal.buffer.yDisp + terminal.rows - 1
    }

    /// Whether the alternate screen buffer is active.
    ///
    /// True when a full-screen TUI (vim, less, codex, …) has switched in via
    /// DECSET 1049 / 47 / 1047. Selection / shell-integration logic that
    /// keys off scroll-invariant row ids should treat alt-screen ids as
    /// disjoint from the primary buffer's.
    public var isAlternateBuffer: Bool { terminal.isCurrentBufferAlternate }

    /// Lifts a viewport-relative row (0 ..< rows) into a scroll-invariant
    /// buffer row id.
    public func scrollInvariantRow(forViewportRow viewportRow: Int) -> Int {
        terminal.buffer.yDisp + viewportRow
    }

    /// Maps a scroll-invariant row id back to a viewport-relative row.
    /// Returns `nil` if the row is no longer in the visible viewport.
    public func viewportRow(forScrollInvariantRow row: Int) -> Int? {
        let v = row - terminal.buffer.yDisp
        return (0..<terminal.rows).contains(v) ? v : nil
    }

    /// Atomically captures a snapshot together with the scroll-invariant row
    /// id of its top line and the alt-screen flag.
    ///
    /// Use this instead of reading `topScrollInvariantRow` and calling
    /// `createSnapshot` separately: in between those two reads the PTY thread
    /// could feed bytes that bump `yDisp`, leaving the caller with a snapshot
    /// whose top row no longer matches the row id it captured.
    ///
    /// `scrollbackOffset` shares semantics with `createSnapshot(scrollbackOffset:)`,
    /// and the returned `topScrollInvariantRow` is computed using the same
    /// clamp so the two never drift.
    public func createSnapshotWithAnchor(scrollbackOffset: Int = 0)
        -> (snapshot: ScreenBufferSnapshot, topScrollInvariantRow: Int, isAlternate: Bool)
    {
        let snapshot = createSnapshot(scrollbackOffset: scrollbackOffset)
        // Mirror the exact clamp from createSnapshot so the returned top row
        // matches the snapshot's first line even if the caller passes an
        // out-of-range offset.
        let maxScrollback = terminal.buffer.yDisp
        let effectiveOffset = max(0, min(scrollbackOffset, maxScrollback))
        let top = terminal.buffer.yDisp - effectiveOffset
        return (snapshot, top, terminal.isCurrentBufferAlternate)
    }

    // MARK: - Mouse mode

    /// SwiftTerm's current mouse reporting mode, projected onto a Hi-Terms-owned
    /// enum so callers (notably `TerminalUI`) don't need to import SwiftTerm.
    public var mouseReportingMode: MouseReportingMode {
        switch terminal.mouseMode {
        case .off: return .off
        case .x10: return .x10
        case .vt200: return .vt200
        case .buttonEventTracking: return .buttonEventTracking
        case .anyEvent: return .anyEvent
        }
    }
}

/// Mirror of SwiftTerm's `Terminal.MouseMode` so the UI layer can gate mouse
/// reporting without taking a direct dependency on SwiftTerm types.
public enum MouseReportingMode {
    case off
    case x10
    case vt200
    case buttonEventTracking
    case anyEvent
}

/// Internal delegate adapter for SwiftTerm callbacks.
private class SwiftTermDelegateAdapter: TerminalDelegate {
    var onSendData: ((Data) -> Void)?
    var onCursorStyleChanged: ((SwiftTerm.CursorStyle) -> Void)?
    var onCursorShown: (() -> Void)?
    var onCursorHidden: (() -> Void)?
    var onBell: (() -> Void)?
    var onHostCwdChanged: (() -> Void)?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        onSendData?(Data(data))
    }

    func cursorStyleChanged(source: Terminal, newStyle: SwiftTerm.CursorStyle) {
        onCursorStyleChanged?(newStyle)
    }

    func showCursor(source: Terminal) {
        onCursorShown?()
    }

    func hideCursor(source: Terminal) {
        onCursorHidden?()
    }

    func bell(source: Terminal) {
        onBell?()
    }

    func hostCurrentDirectoryUpdated(source: Terminal) {
        onHostCwdChanged?()
    }

    func sizeChanged(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
}
