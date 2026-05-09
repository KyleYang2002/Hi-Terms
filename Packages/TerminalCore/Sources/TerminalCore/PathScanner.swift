import Foundation

/// A regex match describing a candidate file path inside a `RowText.text`.
///
/// `path` is the raw literal as captured (may include `~/`, `./`, `file://…`).
/// Resolution to an absolute `URL` and existence checks happen in higher-level
/// detectors so this type can stay free of UI / file-system dependencies.
public struct PathMatch: Equatable, Sendable {
    public let charRange: Range<String.Index>
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(charRange: Range<String.Index>, path: String, line: Int?, column: Int?) {
        self.charRange = charRange
        self.path = path
        self.line = line
        self.column = column
    }
}

/// Scans a single line of terminal text for candidate file-path references.
///
/// The grammar is intentionally conservative — codex / Claude Code outputs vary
/// widely and false positives are far more annoying than missed paths. Three
/// patterns are tried, longest-prefix first:
///
/// 1. `file://[host]/path[:line[:col]]`
/// 2. `(~|.|..)?/path[:line[:col]]` (absolute or `~/`-rooted)
/// 3. `(segment/)+segment[.ext][:line[:col]]` (relative; must contain at least
///    one `/` to avoid matching identifiers like `foo.bar`)
///
/// Filtering is purely lexical: existence checks and cwd containment live in the
/// `BareTextPathDetector` layer.
public enum PathScanner {
    private static let stopChars: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "()[]{}<>\"'`,")
        return set
    }()

    private static let regex: NSRegularExpression = {
        // Order matters — alternation is matched left-to-right by NSRegularExpression.
        // Each branch is anchored loosely (no \b inside, since paths can contain
        // `.` and `_` which \b treats as word boundaries unpredictably). Boundary
        // filtering is applied in code below.
        let patterns = [
            // file://[host]/...:line:col
            #"file://[^\s/]*?/[^\s)\]>"'`]+(?::\d+(?::\d+)?)?"#,
            // ~/, ./, ../, /abs (absolute or anchored relative)
            #"(?:~|\.{1,2})?/[^\s:)\]>"'`]+(?::\d+(?::\d+)?)?"#,
            // pure relative with at least one `/` (no leading `.` or `~`)
            #"(?:[\w.\-]+/)+[\w.\-]+(?::\d+(?::\d+)?)?"#
        ]
        let combined = patterns.map { "(?:\($0))" }.joined(separator: "|")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: combined, options: [])
    }()

    /// Scans `text` and returns non-overlapping path matches, left-to-right.
    public static func scan(_ text: String) -> [PathMatch] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var matches: [PathMatch] = []
        regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
            guard let result, result.range.location != NSNotFound else { return }
            let nsRange = result.range
            guard let swiftRange = Range(nsRange, in: text) else { return }

            // Reject matches whose immediate left neighbor is a word char unless
            // it's part of a recognized prefix (`/`, `~`, `.`). This kills cases
            // like the trailing `bc/def` inside `abc/def` already-matched word —
            // but enumerateMatches handles non-overlap, so this primarily guards
            // matches that started after a non-space word character such as
            // `--option=path/file`.
            let raw = String(text[swiftRange])
            let trimmed = trimTrailingPunctuation(raw)
            guard !trimmed.isEmpty else { return }
            // Recompute the swiftRange after trailing trim.
            let upperBound = text.index(swiftRange.lowerBound, offsetBy: trimmed.count)
            let finalRange = swiftRange.lowerBound..<upperBound

            let (path, line, column) = splitLineCol(trimmed)
            // Reject paths that didn't end up containing a `/` (defensive — the
            // regex enforces this for branch 3, but let's double-check after trim).
            guard path.contains("/") else { return }

            matches.append(PathMatch(charRange: finalRange, path: path, line: line, column: column))
        }
        return matches
    }

    /// Strips trailing characters that are very likely punctuation rather than
    /// part of the path (sentence terminators, dangling parens, etc.).
    private static func trimTrailingPunctuation(_ s: String) -> String {
        var t = s
        while let last = t.last, ".,;:!?)\"'`]>".contains(last) {
            // Don't strip `:` if it's part of `:line` — i.e. preceded by digit.
            if last == ":", let prev = t.dropLast().last, prev.isNumber { break }
            t.removeLast()
        }
        return t
    }

    /// Splits `raw` into `(path, line?, col?)`. Recognizes `path:line` and
    /// `path:line:col` suffixes; refuses to split when the segment after the
    /// last `:` isn't an integer (e.g. `https://example.com/a` has no line).
    private static func splitLineCol(_ raw: String) -> (path: String, line: Int?, col: Int?) {
        // Don't try to interpret `:` as line separator inside `file://host:port/...`
        // For `file://` we only consider the suffix after the path portion. As a
        // simple heuristic, only split on the *last two* `:` if they're followed by
        // digits, and only if the whole tail looks like `:digits[:digits]`.
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (raw, nil, nil) }

        // Try `path:line:col`
        if parts.count >= 3,
           let col = Int(parts[parts.count - 1]),
           let line = Int(parts[parts.count - 2]) {
            let path = parts[0..<(parts.count - 2)].joined(separator: ":")
            // Reject when path collapsed to empty (e.g. `:1:2`).
            if !path.isEmpty {
                return (path, line, col)
            }
        }
        // Try `path:line`
        if let line = Int(parts.last!) {
            let path = parts[0..<(parts.count - 1)].joined(separator: ":")
            if !path.isEmpty {
                // Special case: file://host/path — `file:` itself ends up split.
                // If joining produces something like `file//host/x` we must keep
                // the `:` after file. Detect by checking the original raw form.
                return (path, line, nil)
            }
        }
        return (raw, nil, nil)
    }
}
