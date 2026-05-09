import AppKit
import Foundation

/// Opens OSC 8 hyperlinks via NSWorkspace, gated by a v0.2 safety policy:
///
/// - `http`, `https`: opened directly (browser).
/// - `file`: opened only when the target resolves inside the supplied `cwd`
///   subtree, after symlink resolution. This blocks malicious sequences like
///   `\e]8;;file:///etc/passwd\e\\…` from being opened by accident.
/// - any other scheme (mailto, ssh, javascript, …): rejected. v0.2 favors a
///   conservative default; broader allow-listing belongs in Configuration.
///
/// The opener is intentionally `enum` (no instances): all callers reach the
/// same policy without needing to thread a singleton through TerminalView.
public enum HyperlinkOpener {
    /// Strategy for actually opening a URL. Production uses NSWorkspace; tests
    /// inject a recording fake. Returning `false` simulates a workspace-level
    /// failure (rare but possible when no app is registered for the scheme).
    public typealias Opener = (URL) -> Bool

    /// Default opener: forwards to `NSWorkspace.shared.open(_:)`.
    public static let defaultOpener: Opener = { NSWorkspace.shared.open($0) }

    /// Attempts to open `raw` according to the v0.2 safety policy.
    ///
    /// - Parameters:
    ///   - raw: The hyperlink string captured from a cell's `hyperlinkURL`.
    ///   - cwd: The current working directory reported by OSC 7. Used to gate
    ///     `file://` URLs to the cwd subtree. When nil, all `file://` URLs are
    ///     rejected.
    ///   - opener: The actual open hook. Defaults to NSWorkspace.
    /// - Returns: true if the URL passed the policy and `opener` reported
    ///   success; false otherwise.
    @discardableResult
    public static func open(
        _ raw: String,
        cwd: URL?,
        opener: Opener = defaultOpener
    ) -> Bool {
        guard let url = URL(string: raw) else {
            UILog.hyperlink.warning("rejected unparseable URL: \(raw, privacy: .public)")
            return false
        }
        switch url.scheme?.lowercased() {
        case "http", "https":
            return opener(url)
        case "file":
            guard let cwd, isInside(url, cwd: cwd) else {
                UILog.hyperlink.warning("rejected file:// outside cwd: \(raw, privacy: .public)")
                return false
            }
            return opener(url)
        default:
            UILog.hyperlink.warning("rejected scheme: \(url.scheme ?? "nil", privacy: .public)")
            return false
        }
    }

    /// Same gate the OSC 8 path uses for `file://`, exposed for non-OSC-8
    /// callers (notably the bare-text path detector). Returns true when `url`
    /// would be accepted by `open(...)`'s file-scheme branch — i.e. `cwd` is
    /// non-nil and `url` resolves inside its subtree after symlink resolution.
    public static func canOpenFile(_ url: URL, cwd: URL?) -> Bool {
        guard let cwd else { return false }
        return isInside(url, cwd: cwd)
    }

    /// True when `url` resolves to a path inside `cwd`'s subtree (inclusive).
    /// Both sides are standardized and symlink-resolved before comparison so a
    /// `~/Desktop -> /Users/x/Desktop` symlink doesn't sneak past.
    static func isInside(_ url: URL, cwd: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = cwd.standardizedFileURL.resolvingSymlinksInPath().path
        // Equal paths count as "inside" — opening cwd itself is allowed.
        if target == root { return true }
        // Append a trailing "/" so /Users/x/Desktop2 doesn't pass as a child of /Users/x/Desktop.
        let rootWithSep = root.hasSuffix("/") ? root : root + "/"
        return target.hasPrefix(rootWithSep)
    }
}
