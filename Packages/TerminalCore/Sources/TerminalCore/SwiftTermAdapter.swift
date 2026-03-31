import Foundation
@preconcurrency import SwiftTerm

/// Wraps SwiftTerm's `Terminal` as a `TerminalParser` implementation.
///
/// Strategy B: SwiftTerm owns the terminal state (buffer, cursor, attributes).
/// Hi-Terms reads cell data from SwiftTerm's buffer for rendering via snapshots.
public final class SwiftTermAdapter: TerminalParser {
    public weak var delegate: TerminalParserDelegate?

    /// The underlying SwiftTerm terminal instance.
    public let terminal: Terminal
    private let delegateAdapter: SwiftTermDelegateAdapter

    public init(cols: Int = 80, rows: Int = 25) {
        self.delegateAdapter = SwiftTermDelegateAdapter()
        self.terminal = Terminal(delegate: delegateAdapter, options: TerminalOptions(cols: cols, rows: rows))
        delegateAdapter.onBufferUpdated = { [weak self] in
            guard let self = self else { return }
            self.delegate?.parser(self, didReceiveAction: .bufferUpdated)
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
    public func createSnapshot() -> ScreenBufferSnapshot {
        let rows = terminal.rows
        let cols = terminal.cols
        var cells = [[Cell]]()
        cells.reserveCapacity(rows)

        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else {
                cells.append(Array(repeating: .empty, count: cols))
                continue
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
            cells.append(rowCells)
        }

        return ScreenBufferSnapshot(
            cells: cells,
            cursor: CursorState(
                row: terminal.buffer.y,
                col: terminal.buffer.x,
                visible: true
            ),
            rows: rows,
            cols: cols
        )
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
    var onBufferUpdated: (() -> Void)?

    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    func rangeChanged(source: Terminal, startY: Int, endY: Int) {
        onBufferUpdated?()
    }

    func sizeChanged(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
}
