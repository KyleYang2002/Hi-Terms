import Foundation
import TerminalCore

/// A validated bare-text path candidate ready to be dispatched to an editor.
public struct BareTextHit: Equatable, Sendable {
    public let absURL: URL
    public let line: Int?
    public let column: Int?
    /// Cell-column range covered by the match in its source row.
    public let cellRange: ClosedRange<Int>
}

/// Detects file-path-shaped substrings in a single terminal row, resolves them
/// to absolute URLs, and validates each candidate against the same safety gate
/// used by `HyperlinkOpener` (must live inside `cwd`) plus a real-filesystem
/// existence check.
///
/// Per-row results are cached keyed by `(row text, cwd path)` so a high-frequency
/// `mouseMoved` stream doesn't re-scan the same line every event.
public final class BareTextPathDetector {
    public typealias FileExistsCheck = (URL) -> Bool

    private struct CacheKey: Hashable {
        let text: String
        let cwdPath: String?
    }

    private let fileExists: FileExistsCheck
    private let cacheCapacity: Int
    private var cache: [CacheKey: [BareTextHit]] = [:]
    private var cacheOrder: [CacheKey] = []

    public init(
        cacheCapacity: Int = 64,
        fileExists: @escaping FileExistsCheck = { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    ) {
        self.cacheCapacity = max(1, cacheCapacity)
        self.fileExists = fileExists
    }

    /// All validated hits for the row, ordered left-to-right.
    public func allMatches(rowText: RowText, cwd: URL?) -> [BareTextHit] {
        let key = CacheKey(text: rowText.text, cwdPath: cwd?.path)
        if let cached = cache[key] {
            promote(key)
            return cached
        }
        let matches = compute(rowText: rowText, cwd: cwd)
        store(key: key, value: matches)
        return matches
    }

    /// Returns the hit (if any) whose cell range covers `col`.
    public func match(rowText: RowText, cwd: URL?, atCol col: Int) -> BareTextHit? {
        allMatches(rowText: rowText, cwd: cwd).first { $0.cellRange.contains(col) }
    }

    /// Drops cached results. Call when the file system may have changed in a
    /// way that invalidates a previous existence check (e.g. after a known git
    /// checkout) — for v0.0.4 we rely on row-text changes to flush; this hook is
    /// here for tests and future hooks.
    public func clearCache() {
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    // MARK: - Internals

    private func compute(rowText: RowText, cwd: URL?) -> [BareTextHit] {
        let candidates = PathScanner.scan(rowText.text)
        guard !candidates.isEmpty else { return [] }

        var hits: [BareTextHit] = []
        hits.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard let absURL = resolve(path: candidate.path, cwd: cwd) else { continue }
            // Must live in cwd subtree (same rule HyperlinkOpener applies to
            // OSC 8 file:// links). Without a cwd we conservatively reject —
            // there's no anchor to bound relative paths against.
            guard HyperlinkOpener.canOpenFile(absURL, cwd: cwd) else { continue }
            // Must actually exist on disk — kills "foo/bar" identifiers and
            // typo-paths that look right but aren't.
            guard fileExists(absURL) else { continue }
            guard let cellRange = rowText.cellRange(forCharRange: candidate.charRange) else {
                continue
            }
            hits.append(BareTextHit(
                absURL: absURL,
                line: candidate.line,
                column: candidate.column,
                cellRange: cellRange
            ))
        }
        return hits
    }

    /// Turns a raw path literal (`~/x`, `./x`, `/x`, `x/y`, or `file://…`) into
    /// an absolute file URL anchored at `cwd` when needed.
    private func resolve(path: String, cwd: URL?) -> URL? {
        if path.hasPrefix("file://") {
            return URL(string: path)
        }
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent(String(path.dropFirst(2)))
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        // Relative path — needs an anchor.
        guard let cwd else { return nil }
        return cwd.appendingPathComponent(path)
    }

    // MARK: - LRU bookkeeping

    private func promote(_ key: CacheKey) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
        }
        cacheOrder.append(key)
    }

    private func store(key: CacheKey, value: [BareTextHit]) {
        cache[key] = value
        cacheOrder.append(key)
        if cacheOrder.count > cacheCapacity {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }
}
