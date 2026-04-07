import Foundation

/// A single character cell in the terminal grid.
public struct Cell: Equatable, Sendable {
    public var character: Character
    public var attributes: TextAttributes
    /// Number of terminal columns this character occupies (1 for normal, 2 for CJK/fullwidth, 0 for continuation).
    public var width: Int8

    public init(character: Character = " ", attributes: TextAttributes = .default, width: Int8 = 1) {
        self.character = character
        self.attributes = attributes
        self.width = width
    }

    public static let empty = Cell()
}
