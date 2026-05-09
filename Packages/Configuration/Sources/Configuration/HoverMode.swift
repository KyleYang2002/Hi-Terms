import Foundation

/// Hover-highlight trigger policy for OSC 8 hyperlinks and bare-text paths.
///
/// - `always`: highlight on plain mouseMoved (default; matches v0.2 behavior).
/// - `commandKey`: only highlight while ⌘ is held; ⌘+click still works.
/// - `off`: never highlight on hover; ⌘+click still opens links/paths.
public enum HoverMode: String, Sendable, CaseIterable {
    case always
    case commandKey
    case off
}
