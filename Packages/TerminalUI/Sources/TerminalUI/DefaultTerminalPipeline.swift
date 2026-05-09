import Foundation
import TerminalCore
import TerminalRenderer
import PTYKit

/// Concrete implementation of TerminalPipeline that connects:
/// PTY → SwiftTermAdapter → DirtyRegion → RenderCoordinator
///
/// Components are created externally and injected via init for testability.
/// The AppDelegate assembles all components and passes them in.
public final class DefaultTerminalPipeline: TerminalPipeline {
    // MARK: - Protocol requirements

    public let parser: any TerminalParser
    public let screenBuffer: ScreenBuffer

    // MARK: - Implementation-specific properties

    /// Dirty region tracker for incremental rendering.
    public let dirtyRegion: DirtyRegion

    /// Coordinates PTY thread snapshots with main thread rendering.
    public let renderCoordinator: RenderCoordinator

    /// The SwiftTerm adapter (public for scrollback snapshot access).
    public let adapter: SwiftTermAdapter

    /// Scrollback offset set by TerminalView on scroll events.
    /// Read by rangeChangedHandler when creating snapshots.
    /// This avoids cross-thread access to SwiftTerm from the main thread.
    public var scrollbackOffset: Int = 0

    /// Optional sink for terminal BEL events. Set by `AppDelegate` once a
    /// `BellCoordinator` exists for this window. The pipeline routes
    /// `ParserAction.bell` here on the main thread; non-bell parser actions
    /// are not forwarded (SwiftTerm owns buffer state directly).
    public var bellHandler: BellHandler?

    // MARK: - Internal components

    private let ptyProcess: PTYProcess
    private let parserDelegateBridge = ParserDelegateBridge()

    // MARK: - Init

    /// Creates a pipeline with externally-assembled components.
    ///
    /// Wires the callback chain:
    /// - adapter.sendHandler → ptyProcess.write (terminal responses back to PTY)
    /// - adapter.rangeChangedHandler → dirtyRegion.merge → createSnapshot → coordinator.submitSnapshot
    /// - adapter.delegate → bridge → bellHandler (BEL events on main thread)
    public init(
        ptyProcess: PTYProcess,
        adapter: SwiftTermAdapter,
        dirtyRegion: DirtyRegion,
        renderCoordinator: RenderCoordinator
    ) {
        self.ptyProcess = ptyProcess
        self.adapter = adapter
        self.parser = adapter
        self.screenBuffer = ScreenBuffer(rows: adapter.terminal.rows, cols: adapter.terminal.cols)
        self.dirtyRegion = dirtyRegion
        self.renderCoordinator = renderCoordinator

        // Wire terminal response data (DA replies, cursor reports) back to PTY
        adapter.sendHandler = { [weak ptyProcess] data in
            ptyProcess?.write(data: data)
        }

        // Wire rangeChanged → dirty region → snapshot → render coordinator
        // SwiftTerm's rangeChanged passes inclusive (startY, endY),
        // DirtyRegion.merge(rows:) takes Range<Int> (half-open), so endY + 1
        adapter.rangeChangedHandler = { [weak self] startY, endY in
            guard let self else { return }
            self.dirtyRegion.merge(rows: startY..<(endY + 1))
            let snapshot = self.adapter.createSnapshot(scrollbackOffset: self.scrollbackOffset)
            self.renderCoordinator.submitSnapshot(snapshot)
        }

        // Route ParserAction.bell to the optional bellHandler. Other actions
        // are intentionally ignored — SwiftTerm owns the buffer; the bridge
        // exists purely to surface BEL.
        parserDelegateBridge.onBell = { [weak self] in
            guard let self else { return }
            // Hop to main; BellHandler implementations live on @MainActor.
            DispatchQueue.main.async { [weak self] in
                self?.bellHandler?.bellRequested()
            }
        }
        adapter.delegate = parserDelegateBridge
    }

    // MARK: - TerminalPipeline

    /// Connects PTY data output to the parser and starts the display link.
    public func start() {
        ptyProcess.setDataHandler { [weak self] data in
            self?.adapter.parse(data: data)
        }
    }

    /// Terminates the PTY process.
    public func stop() {
        ptyProcess.terminate()
    }

    /// Writes data to the PTY (user input).
    public func write(data: Data) {
        ptyProcess.write(data: data)
    }

    /// Resizes both the PTY window and SwiftTerm's terminal model.
    public func resize(cols: Int, rows: Int) {
        ptyProcess.resize(cols: UInt16(cols), rows: UInt16(rows))
        adapter.terminal.resize(cols: cols, rows: rows)
    }
}

/// Internal helper that turns the `TerminalParserDelegate` protocol into a
/// closure callback. Kept private so the pipeline can hand SwiftTerm a stable
/// delegate object without exposing the wiring.
private final class ParserDelegateBridge: TerminalParserDelegate {
    var onBell: (() -> Void)?

    func parser(_ parser: any TerminalParser, didReceiveAction action: ParserAction) {
        switch action {
        case .bell:
            onBell?()
        default:
            break
        }
    }
}
