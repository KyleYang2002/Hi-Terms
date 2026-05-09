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

    /// Per-session bare-text path detector. Holds the LRU cache that keeps
    /// `mouseMoved`-driven scans out of the regex/stat hot path. Lives on the
    /// pipeline so each session's cache is isolated and lifetime-bound.
    public let bareTextDetector = BareTextPathDetector()

    /// V0.0.3 T1: forward the adapter's shell integration state so callers
    /// reach it via the `TerminalPipeline` protocol without importing
    /// `SwiftTermAdapter`.
    public var shellIntegration: ShellIntegrationState { adapter.shellIntegration }

    /// Scrollback offset set by TerminalView on scroll events.
    /// Read by rangeChangedHandler when creating snapshots.
    /// This avoids cross-thread access to SwiftTerm from the main thread.
    public var scrollbackOffset: Int = 0

    /// Optional sink for terminal BEL events. Set by `AppDelegate` once a
    /// `BellCoordinator` exists for this window. The pipeline routes
    /// `ParserAction.bell` here on the main thread; non-bell parser actions
    /// are not forwarded (SwiftTerm owns buffer state directly).
    public var bellHandler: BellHandler?

    /// Optional sink for "the absolute row at the viewport top changed".
    ///
    /// SwiftTerm rolls `yDisp` forward whenever PTY output pushes new lines
    /// into scrollback, but neither the adapter nor the pipeline owns the
    /// selection state that would need to reproject. Wave 2-C has TerminalView
    /// install a hook here so it can call `publishSelectionOverlay()` and keep
    /// any active selection visually anchored to the same buffer rows.
    ///
    /// Fired on the main thread, only when the value actually changes.
    public var onYDispChanged: ((Int) -> Void)?

    /// Optional sink for "the alternate-screen flag flipped".
    ///
    /// Switching into the alt buffer (DECSET 1049 / 47 / 1047) makes any
    /// selection rooted in the primary buffer's row ids meaningless; switching
    /// back out clobbers the selection that may have been built against the
    /// alt buffer. Either edge is reported here so TerminalView can drop the
    /// selection.
    ///
    /// Fired on the main thread with the *new* value, only on edges.
    public var onAlternateBufferChanged: ((Bool) -> Void)?

    /// Optional sink for "any shell-integration change occurred". Fires for
    /// every OSC 7 / OSC 133 event so TerminalView can republish the shell
    /// marker overlay without re-implementing change classification.
    ///
    /// Fired on the main thread.
    public var onShellMarkersChanged: (() -> Void)?

    /// Optional sink for "OSC 7 reported a new cwd". TerminalWindowController
    /// uses this to update the window title without subscribing to
    /// `shellIntegration.onChange` directly (the pipeline owns that
    /// subscription so multiple downstream consumers can fan out).
    ///
    /// Fired on the main thread.
    public var onShellCwdChanged: ((URL?, String?) -> Void)?

    // MARK: - Internal components

    private let ptyProcess: PTYProcess
    private let parserDelegateBridge = ParserDelegateBridge()

    /// Last `yDisp` (= `topScrollInvariantRow`) value reported via the hook.
    /// Read/written only inside `rangeChangedHandler`, which the adapter calls
    /// on the same parser thread, so no extra synchronization is needed.
    private var lastTopScrollInvariantRow: Int = 0

    /// Last `isAlternateBuffer` value reported via the hook. Same threading
    /// note as `lastTopScrollInvariantRow`.
    private var lastIsAlternateBuffer: Bool = false

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

        // Seed the change-detector caches with the adapter's current state so
        // the very first rangeChanged callback doesn't fire a spurious hop.
        self.lastTopScrollInvariantRow = adapter.topScrollInvariantRow
        self.lastIsAlternateBuffer = adapter.isAlternateBuffer

        // Wire rangeChanged → dirty region → snapshot → render coordinator
        // SwiftTerm's rangeChanged passes inclusive (startY, endY),
        // DirtyRegion.merge(rows:) takes Range<Int> (half-open), so endY + 1
        adapter.rangeChangedHandler = { [weak self] startY, endY in
            guard let self else { return }
            self.dirtyRegion.merge(rows: startY..<(endY + 1))
            let snapshot = self.adapter.createSnapshot(scrollbackOffset: self.scrollbackOffset)
            self.renderCoordinator.submitSnapshot(snapshot)
            self.detectAndForwardSelectionEdges()
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

        // Fan-out shell-integration events. The adapter publishes a single
        // `onChange` slot, so we centralize the subscription here and dispatch
        // to multiple downstream hooks (markers / cwd). Downstream subscribers
        // (`TerminalView`, `TerminalWindowController`) read the dedicated
        // hooks instead of touching `shellIntegration.onChange` directly,
        // which would clobber each other.
        adapter.shellIntegration.onChange = { [weak self] change in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onShellMarkersChanged?()
                if case let .cwdChanged(url, host, _) = change {
                    self.onShellCwdChanged?(url, host)
                }
            }
        }
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

    // MARK: - Selection-relevant edge detection

    /// Compares the adapter's current `topScrollInvariantRow` /
    /// `isAlternateBuffer` against the last reported values and fires the
    /// matching hook on the main thread when either edge is crossed.
    ///
    /// Called from `rangeChangedHandler`, which the adapter invokes whenever
    /// it has just finished feeding bytes — that's also when SwiftTerm has
    /// fully applied scroll/alt-buffer transitions, so reading both values
    /// here is consistent with the snapshot we just shipped.
    private func detectAndForwardSelectionEdges() {
        let newTop = adapter.topScrollInvariantRow
        if newTop != lastTopScrollInvariantRow {
            lastTopScrollInvariantRow = newTop
            if let hook = onYDispChanged {
                DispatchQueue.main.async { hook(newTop) }
            }
        }

        let newAlt = adapter.isAlternateBuffer
        if newAlt != lastIsAlternateBuffer {
            lastIsAlternateBuffer = newAlt
            if let hook = onAlternateBufferChanged {
                DispatchQueue.main.async { hook(newAlt) }
            }
        }
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
