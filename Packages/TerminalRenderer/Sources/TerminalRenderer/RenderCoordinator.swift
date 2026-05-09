import AppKit
import QuartzCore
import os
import TerminalCore

/// Coordinates background buffer updates with main-thread rendering via CADisplayLink.
///
/// The PTY I/O thread calls `submitSnapshot(_:)` to provide new buffer state.
/// A CADisplayLink callback on the main thread picks up the latest snapshot and
/// triggers the renderer. This ensures rendering is capped at display refresh rate
/// and multiple buffer updates between frames are coalesced automatically.
///
/// V0.2 also tracks an optional `SelectionOverlay`. The UI layer pushes new
/// overlays via `updateSelection(_:)`; the next display-link tick forwards the
/// latest value to the renderer alongside the buffer snapshot. The overlay is
/// independent of the dirty-region pipeline, so changes to the selection alone
/// (without buffer mutation) are still applied, because every tick re-supplies
/// the current overlay to the renderer.
public final class RenderCoordinator: NSObject, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var latestSnapshot: ScreenBufferSnapshot?
    private var pendingSelection: SelectionOverlay?
    private var displayLink: CADisplayLink?
    private let dirtyRegion: DirtyRegion

    public weak var renderer: (any TerminalRendering)?
    public weak var targetLayer: CALayer?

    public init(dirtyRegion: DirtyRegion) {
        self.dirtyRegion = dirtyRegion
        super.init()
    }

    /// Submits a new buffer snapshot from the PTY I/O thread.
    public func submitSnapshot(_ snapshot: ScreenBufferSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        latestSnapshot = snapshot
    }

    /// Replaces the current selection overlay. Pass `nil` to clear.
    /// Safe to call from any thread; rendering happens on the next display tick.
    public func updateSelection(_ overlay: SelectionOverlay?) {
        lock.lock()
        defer { lock.unlock() }
        pendingSelection = overlay
    }

    /// Starts the CADisplayLink render loop on the main RunLoop.
    public func startDisplayLink() {
        guard displayLink == nil else { return }
        guard let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(onDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    /// Stops the CADisplayLink render loop.
    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// CADisplayLink callback — runs on main thread at display refresh rate.
    @objc private func onDisplayLink(_ displayLink: CADisplayLink) {
        lock.lock()
        let snapshot = latestSnapshot
        let selection = pendingSelection
        lock.unlock()

        guard let snapshot, let renderer, let targetLayer else { return }

        renderer.render(
            buffer: snapshot,
            dirtyRegion: dirtyRegion,
            cursor: snapshot.cursor,
            selection: selection,
            into: targetLayer
        )
    }
}
