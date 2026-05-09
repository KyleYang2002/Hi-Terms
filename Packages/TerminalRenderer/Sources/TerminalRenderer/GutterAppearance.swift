import CoreGraphics
import Foundation

/// Visual parameters for the OSC 133 command-band gutter rendered by
/// `CoreTextRenderer`. Hue is fixed (systemBlue / systemGreen / systemRed) so
/// the band tracks light/dark mode automatically; only alpha, width, and the
/// prompt-top separator toggle are user-tunable.
public struct GutterAppearance: Sendable, Equatable {
    public var runningAlpha: CGFloat
    public var successAlpha: CGFloat
    public var failureAlpha: CGFloat
    public var widthPx: CGFloat
    public var separatorEnabled: Bool

    public init(
        runningAlpha: CGFloat,
        successAlpha: CGFloat,
        failureAlpha: CGFloat,
        widthPx: CGFloat,
        separatorEnabled: Bool
    ) {
        self.runningAlpha = runningAlpha
        self.successAlpha = successAlpha
        self.failureAlpha = failureAlpha
        self.widthPx = widthPx
        self.separatorEnabled = separatorEnabled
    }

    /// Matches the v0.0.4 hardcoded values; used as the construction default
    /// so existing tests and call sites keep their pre-config behavior.
    public static let `default` = GutterAppearance(
        runningAlpha: 0.45,
        successAlpha: 0.55,
        failureAlpha: 0.65,
        widthPx: 3.0,
        separatorEnabled: true
    )
}
