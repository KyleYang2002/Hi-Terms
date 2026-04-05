import Foundation
import os

/// Thread-safe dirty region tracker for terminal rendering.
///
/// Collects row indices that need redrawing. Parser thread calls `merge()`,
/// renderer thread calls `swapAndClear()` on the CADisplayLink callback.
/// Protected by `OSAllocatedUnfairLock` for minimal overhead.
public final class DirtyRegion: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var dirtyRows = IndexSet()

    public init() {}

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirtyRows.isEmpty
    }

    /// Merges additional dirty rows. Called from the PTY I/O thread.
    public func merge(_ rows: IndexSet) {
        lock.lock()
        defer { lock.unlock() }
        dirtyRows.formUnion(rows)
    }

    /// Merges a single row.
    public func merge(row: Int) {
        merge(IndexSet(integer: row))
    }

    /// Merges a range of rows.
    public func merge(rows range: Range<Int>) {
        merge(IndexSet(integersIn: range))
    }

    /// Atomically swaps out the dirty region and clears it.
    /// Called from the main thread (CADisplayLink callback).
    public func swapAndClear() -> IndexSet {
        lock.lock()
        defer { lock.unlock() }
        let result = dirtyRows
        dirtyRows = IndexSet()
        return result
    }
}
