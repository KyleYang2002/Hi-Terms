import AppKit
import Foundation

/// Dispatches a validated absolute file path (with optional `:line[:col]`) to
/// an editor. Two channels:
///
/// - `xed` (Xcode CLI bundled with Xcode) for known Apple-toolchain extensions
///   — it's the only reliable way to land on a specific line in Xcode.
/// - `vscode://file/` URL scheme for everything else with a line number, which
///   VS Code, Cursor, and a few other editors register handlers for.
/// - `NSWorkspace.open` for plain "open this file" (no line info) — respects the
///   user's default app per-extension.
///
/// On any failure (process can't launch, URL handler isn't registered) we fall
/// back to `NSWorkspace.open(fileURL)` so the user always sees the file open
/// in *something*, even if the line position is lost.
public enum EditorJump {
    public typealias URLOpener = (URL) -> Bool
    public typealias ProcessLauncher = (_ executable: String, _ args: [String]) -> Bool

    private static let xcodeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp",
        "xcodeproj", "xcworkspace", "xcconfig"
    ]

    public static let defaultURLOpener: URLOpener = { NSWorkspace.shared.open($0) }

    public static let defaultProcessLauncher: ProcessLauncher = { exe, args in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        do {
            try proc.run()
            return true
        } catch {
            UILog.hyperlink.warning(
                "EditorJump: failed to launch \(exe, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Opens `absPath`, optionally jumping to `(line, column)`.
    @discardableResult
    public static func open(
        absPath: String,
        line: Int?,
        column: Int?,
        urlOpener: URLOpener = defaultURLOpener,
        processLauncher: ProcessLauncher = defaultProcessLauncher
    ) -> Bool {
        let ext = (absPath as NSString).pathExtension.lowercased()
        let useXcode = xcodeExtensions.contains(ext)

        if useXcode {
            if let line {
                if processLauncher("/usr/bin/xed", ["-l", "\(line)", absPath]) {
                    return true
                }
            } else {
                if processLauncher("/usr/bin/xed", [absPath]) {
                    return true
                }
            }
            // xed unavailable → fall back to system default.
            return fallbackOpen(absPath, urlOpener: urlOpener)
        }

        if let line {
            if let url = vscodeURL(absPath: absPath, line: line, column: column),
               urlOpener(url) {
                return true
            }
            // vscode:// not registered → fall back.
            return fallbackOpen(absPath, urlOpener: urlOpener)
        }

        // No line info → just open the file with the system default.
        return fallbackOpen(absPath, urlOpener: urlOpener)
    }

    /// Builds `vscode://file/<encoded-path>:line[:col]`. Path is percent-encoded
    /// so spaces and special characters survive the URL parse.
    static func vscodeURL(absPath: String, line: Int, column: Int?) -> URL? {
        guard let encoded = absPath.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else { return nil }
        var s = "vscode://file\(encoded):\(line)"
        if let column {
            s += ":\(column)"
        }
        return URL(string: s)
    }

    private static func fallbackOpen(_ absPath: String, urlOpener: URLOpener) -> Bool {
        urlOpener(URL(fileURLWithPath: absPath))
    }
}
