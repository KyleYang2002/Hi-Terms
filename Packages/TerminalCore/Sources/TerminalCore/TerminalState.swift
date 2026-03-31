import Foundation

/// Aggregate terminal state.
public struct TerminalState: Sendable {
    public var buffer: ScreenBufferSnapshot
    public var alternateScreenActive: Bool
    public var bracketedPasteMode: Bool
    public var applicationCursorKeys: Bool

    public init(
        buffer: ScreenBufferSnapshot,
        alternateScreenActive: Bool = false,
        bracketedPasteMode: Bool = false,
        applicationCursorKeys: Bool = false
    ) {
        self.buffer = buffer
        self.alternateScreenActive = alternateScreenActive
        self.bracketedPasteMode = bracketedPasteMode
        self.applicationCursorKeys = applicationCursorKeys
    }
}
