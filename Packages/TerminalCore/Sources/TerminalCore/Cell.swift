import Foundation

/// A single character cell in the terminal grid.
public struct Cell: Equatable, Sendable {
    public var character: Character
    public var attributes: TextAttributes

    public init(character: Character = " ", attributes: TextAttributes = .default) {
        self.character = character
        self.attributes = attributes
    }

    public static let empty = Cell()
}
