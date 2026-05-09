import AppKit
import Foundation

/// Opens OSC 8 hyperlinks via NSWorkspace, gated by a v0.2 safety policy:
///
/// - Schemes are accepted only if listed in `allowedSchemes` (default
///   `{http, https, file}`). Users can broaden via `AppConfig` to add things
///   like `ssh` or `mailto`, or tighten by removing entries.
/// - `file`: even when listed, the target must resolve inside the supplied
///   `cwd` subtree after symlink resolution. This is a hard policy and is
///   not togglable — it blocks `\e]8;;file:///etc/passwd\e\\…` style payloads
///   from being opened by accident.
/// - Anything that fails the above is rejected and logged.
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

    /// Default scheme allowlist used when callers don't override. Mirrors the
    /// v0.2 policy and the `DefaultConfig` value, so `HyperlinkOpener.open`
    /// without an explicit allowlist behaves like v0.0.4.
    public static let defaultAllowedSchemes: Set<String> = ["http", "https", "file"]

    /// Attempts to open `raw` according to the safety policy.
    ///
    /// - Parameters:
    ///   - raw: The hyperlink string captured from a cell's `hyperlinkURL`.
    ///   - cwd: The current working directory reported by OSC 7. Used to gate
    ///     `file://` URLs to the cwd subtree. When nil, all `file://` URLs are
    ///     rejected regardless of presence in `allowedSchemes`.
    ///   - allowedSchemes: Lower-cased set of accepted URL schemes. Defaults
    ///     to `defaultAllowedSchemes`.
    ///   - opener: The actual open hook. Defaults to NSWorkspace.
    /// - Returns: true if the URL passed the policy and `opener` reported
    ///   success; false otherwise.
    @discardableResult
    public static func open(
        _ raw: String,
        cwd: URL?,
        allowedSchemes: Set<String> = defaultAllowedSchemes,
        opener: Opener = defaultOpener
    ) -> Bool {
        guard let url = URL(string: raw) else {
            UILog.hyperlink.warning("rejected unparseable URL: \(raw, privacy: .public)")
            return false
        }
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            UILog.hyperlink.warning("rejected scheme: \(url.scheme ?? "nil", privacy: .public)")
            return false
        }
        if scheme == "file" {
            guard let cwd, isInside(url, cwd: cwd) else {
                UILog.hyperlink.warning("rejected file:// outside cwd: \(raw, privacy: .public)")
                return false
            }
        }
        return opener(url)
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
