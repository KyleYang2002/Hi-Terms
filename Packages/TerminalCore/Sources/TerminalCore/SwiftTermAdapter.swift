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

    public init(cols: Int = 80, rows: Int = 25) {
        self.delegateAdapter = SwiftTermDelegateAdapter()
        self.terminal = Terminal(delegate: delegateAdapter, options: TerminalOptions(cols: cols, rows: rows))
        delegateAdapter.onSendData = { [weak self] data in
            self?.sendHandler?(data)
        }
        delegateAdapter.onRangeChanged = { [weak self] startY, endY in
            guard let self = self else { return }
            self.delegate?.parser(self, didReceiveAction: .bufferUpdated)
            self.rangeChangedHandler?(startY, endY)
        }
    }

    public func parse(data: Data) {
        let bytes = [UInt8](data)
        terminal.feed(byteArray: bytes)
    }

    /// Reads a cell from SwiftTerm's buffer, bridging to Hi-Terms Cell type.
    public func getCell(col: Int, row: Int) -> Cell {
        guard let line = terminal.getLine(row: row), col < line.count else { return .empty }
        let cd = line[col]
        return Cell(
            character: cd.getCharacter(),
            attributes: mapAttributes(cd.attribute)
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
                visible: effectiveOffset == 0  // Hide cursor in scrollback mode
            ),
            rows: rows,
            cols: cols
        )
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
                    attributes: mapAttributes(cd.attribute)
                ))
            } else {
                rowCells.append(.empty)
            }
        }
        return rowCells
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
}

/// Internal delegate adapter for SwiftTerm callbacks.
private class SwiftTermDelegateAdapter: TerminalDelegate {
    var onSendData: ((Data) -> Void)?
    var onRangeChanged: ((Int, Int) -> Void)?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        onSendData?(Data(data))
    }

    func rangeChanged(source: Terminal, startY: Int, endY: Int) {
        onRangeChanged?(startY, endY)
    }

    func sizeChanged(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
}
