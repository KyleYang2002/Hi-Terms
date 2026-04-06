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
public final class RenderCoordinator: NSObject, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var latestSnapshot: ScreenBufferSnapshot?
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

    /// Starts the CADisplayLink render loop on the main RunLoop.
    public func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
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
        lock.unlock()

        guard let snapshot, let renderer, let targetLayer else { return }

        renderer.render(
            buffer: snapshot,
            dirtyRegion: dirtyRegion,
            cursor: snapshot.cursor,
            into: targetLayer
        )
    }
}
