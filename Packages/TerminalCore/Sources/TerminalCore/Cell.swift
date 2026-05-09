import Foundation

/// A single character cell in the terminal grid.
public struct Cell: Equatable, Sendable {
    public var character: Character
    public var attributes: TextAttributes
    /// Number of terminal columns this character occupies (1 for normal, 2 for CJK/fullwidth, 0 for continuation).
    public var width: Int8
    /// OSC 8 hyperlink target URL, or nil when this cell is not part of a hyperlink.
    /// SwiftTerm parses `\e]8;params;URI\e\\` and attaches the URI to each spanned
    /// `CharData.payload`; `SwiftTermAdapter` mirrors that into this field. The URL
    /// string itself is the source of truth — Hi-Terms does not maintain a parallel
    /// atom→URL table.
    public var hyperlinkURL: String?

    public init(
        character: Character = " ",
        attributes: TextAttributes = .default,
        width: Int8 = 1,
        hyperlinkURL: String? = nil
    ) {
        self.character = character
        self.attributes = attributes
        self.width = width
        self.hyperlinkURL = hyperlinkURL
    }

    public static let empty = Cell()
}
