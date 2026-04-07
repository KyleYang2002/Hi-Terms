import AppKit
import Foundation

/// Converts NSEvent keyboard and mouse events into terminal byte sequences.
///
/// Handles special keys, Ctrl combinations, and SGR mouse reporting.
/// Cmd key combinations are filtered (reserved for app shortcuts).
public final class InputHandler {
    private var modifiers: NSEvent.ModifierFlags = []

    public init() {}

    // MARK: - Keyboard

    /// Converts a keyDown event to terminal byte data.
    /// Returns nil if the event should not be sent to the terminal (e.g., Cmd shortcuts).
    public func handleKeyDown(_ event: NSEvent) -> Data? {
        let keyCode = event.keyCode
        let flags = event.modifierFlags

        // Cmd combinations reserved for app shortcuts — do not pass to terminal
        if flags.contains(.command) { return nil }

        // Ctrl combinations
        if flags.contains(.control) {
            return handleCtrlKey(event)
        }

        // Special keys (arrows, function keys, etc.)
        if let specialData = handleSpecialKey(keyCode: keyCode) {
            return specialData
        }

        // Normal character input
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        return characters.data(using: .utf8)
    }

    /// Updates tracked modifier key state.
    public func updateModifiers(_ flags: NSEvent.ModifierFlags) {
        modifiers = flags
    }

    // MARK: - Mouse

    /// Encodes a mouse event as SGR mouse report: ESC [ < Cb ; Cx ; Cy M/m
    ///
    /// - Parameters:
    ///   - event: The NSEvent (used for button number).
    ///   - type: Press, release, or move.
    ///   - col: Terminal column (0-based).
    ///   - row: Terminal row (0-based).
    /// - Returns: SGR-encoded mouse report data, or nil if not reportable.
    public func handleMouseEvent(
        _ event: NSEvent,
        type: MouseEventType,
        col: Int,
        row: Int
    ) -> Data? {
        let button: Int
        switch type {
        case .press:
            switch event.buttonNumber {
            case 0: button = 0   // Left
            case 1: button = 2   // Right
            case 2: button = 1   // Middle
            default: return nil
            }
        case .release:
            button = 0
        case .move:
            button = 35
        }

        let suffix = type == .release ? "m" : "M"
        // SGR uses 1-based coordinates
        let sequence = "\u{1B}[<\(button);\(col + 1);\(row + 1)\(suffix)"
        return sequence.data(using: .utf8)
    }

    /// Returns terminal data for special keys (arrows, function keys, etc.).
    /// Returns nil for normal character keys.
    public func specialKeyData(for keyCode: UInt16) -> Data? {
        handleSpecialKey(keyCode: keyCode)
    }

    // MARK: - Private

    /// Maps special keyCodes to terminal escape sequences.
    private func handleSpecialKey(keyCode: UInt16) -> Data? {
        switch keyCode {
        case 36:  return Data([0x0D])                        // Return → CR
        case 51:  return Data([0x7F])                        // Backspace → DEL
        case 48:  return Data([0x09])                        // Tab → HT
        case 53:  return Data([0x1B])                        // Escape → ESC
        case 126: return Data("\u{1B}[A".utf8)               // Up Arrow
        case 125: return Data("\u{1B}[B".utf8)               // Down Arrow
        case 124: return Data("\u{1B}[C".utf8)               // Right Arrow
        case 123: return Data("\u{1B}[D".utf8)               // Left Arrow
        case 115: return Data("\u{1B}[H".utf8)               // Home
        case 119: return Data("\u{1B}[F".utf8)               // End
        case 116: return Data("\u{1B}[5~".utf8)              // Page Up
        case 121: return Data("\u{1B}[6~".utf8)              // Page Down
        case 117: return Data("\u{1B}[3~".utf8)              // Delete (Fn+Backspace)
        default:  return nil
        }
    }

    /// Maps Ctrl+key combinations to control codes.
    private func handleCtrlKey(_ event: NSEvent) -> Data? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let char = chars.first else { return nil }

        // Ctrl+A (0x01) through Ctrl+Z (0x1A)
        if let asciiValue = char.asciiValue, asciiValue >= 0x61, asciiValue <= 0x7A {
            let controlCode = asciiValue - 0x60
            return Data([controlCode])
        }

        // Special Ctrl combinations
        switch char {
        case "[":  return Data([0x1B])  // Ctrl+[ = ESC
        case "\\": return Data([0x1C])  // Ctrl+\
        case "]":  return Data([0x1D])  // Ctrl+]
        case "/":  return Data([0x1F])  // Ctrl+/
        default:   return nil
        }
    }
}

/// Mouse event types for SGR encoding.
public enum MouseEventType {
    case press
    case release
    case move
}
