import XCTest
import AppKit
@testable import TerminalUI

final class InputHandlerTests: XCTestCase {
    private var handler: InputHandler!

    override func setUp() {
        super.setUp()
        handler = InputHandler()
    }

    // MARK: - Helper

    private func makeKeyEvent(
        keyCode: UInt16,
        characters: String = "",
        charactersIgnoringModifiers: String? = nil,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // MARK: - Special Keys

    func testReturnKeyProducesCarriageReturn() {
        let event = makeKeyEvent(keyCode: 36, characters: "\r")!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x0D]))
    }

    func testBackspaceProducesDEL() {
        let event = makeKeyEvent(keyCode: 51, characters: "\u{7F}")!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x7F]))
    }

    func testTabProducesTab() {
        let event = makeKeyEvent(keyCode: 48, characters: "\t")!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x09]))
    }

    func testEscapeProducesESC() {
        let event = makeKeyEvent(keyCode: 53, characters: "\u{1B}")!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x1B]))
    }

    // MARK: - Arrow Keys

    func testUpArrow() {
        let event = makeKeyEvent(keyCode: 126)!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data("\u{1B}[A".utf8))
    }

    func testDownArrow() {
        let event = makeKeyEvent(keyCode: 125)!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data("\u{1B}[B".utf8))
    }

    func testRightArrow() {
        let event = makeKeyEvent(keyCode: 124)!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data("\u{1B}[C".utf8))
    }

    func testLeftArrow() {
        let event = makeKeyEvent(keyCode: 123)!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data("\u{1B}[D".utf8))
    }

    // MARK: - Navigation Keys

    func testHomeKey() {
        let event = makeKeyEvent(keyCode: 115)!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data("\u{1B}[H".utf8))
    }

    func testEndKey() {
        let event = makeKeyEvent(keyCode: 119)!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data("\u{1B}[F".utf8))
    }

    func testPageUp() {
        let event = makeKeyEvent(keyCode: 116)!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data("\u{1B}[5~".utf8))
    }

    func testPageDown() {
        let event = makeKeyEvent(keyCode: 121)!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data("\u{1B}[6~".utf8))
    }

    func testDeleteKey() {
        let event = makeKeyEvent(keyCode: 117)!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data("\u{1B}[3~".utf8))
    }

    // MARK: - Ctrl Combinations

    func testCtrlCProducesETX() {
        let event = makeKeyEvent(
            keyCode: 8, // 'c' keyCode
            characters: "\u{03}",
            charactersIgnoringModifiers: "c",
            modifierFlags: .control
        )!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x03]))
    }

    func testCtrlAProducesSOH() {
        let event = makeKeyEvent(
            keyCode: 0, // 'a' keyCode
            characters: "\u{01}",
            charactersIgnoringModifiers: "a",
            modifierFlags: .control
        )!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x01]))
    }

    func testCtrlZProducesSUB() {
        let event = makeKeyEvent(
            keyCode: 6, // 'z' keyCode
            characters: "\u{1A}",
            charactersIgnoringModifiers: "z",
            modifierFlags: .control
        )!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x1A]))
    }

    func testCtrlBracketProducesESC() {
        let event = makeKeyEvent(
            keyCode: 33, // '[' keyCode
            characters: "\u{1B}",
            charactersIgnoringModifiers: "[",
            modifierFlags: .control
        )!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x1B]))
    }

    func testCtrlBackslash() {
        let event = makeKeyEvent(
            keyCode: 42, // '\' keyCode
            characters: "\u{1C}",
            charactersIgnoringModifiers: "\\",
            modifierFlags: .control
        )!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x1C]))
    }

    func testCtrlCloseBracket() {
        let event = makeKeyEvent(
            keyCode: 30, // ']' keyCode
            characters: "\u{1D}",
            charactersIgnoringModifiers: "]",
            modifierFlags: .control
        )!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x1D]))
    }

    func testCtrlSlash() {
        let event = makeKeyEvent(
            keyCode: 44, // '/' keyCode
            characters: "\u{1F}",
            charactersIgnoringModifiers: "/",
            modifierFlags: .control
        )!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, Data([0x1F]))
    }

    // MARK: - Cmd Key Filtering

    func testCmdKeyReturnsNil() {
        let event = makeKeyEvent(
            keyCode: 8, // 'c' keyCode
            characters: "c",
            modifierFlags: .command
        )!
        let data = handler.handleKeyDown(event)
        XCTAssertNil(data, "Cmd combinations should not be sent to terminal")
    }

    // MARK: - Normal Characters

    func testNormalCharacterReturnsUTF8() {
        // Use a keyCode that doesn't match any special key
        let event = makeKeyEvent(keyCode: 0, characters: "a")!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, "a".data(using: .utf8))
    }

    func testUnicodeCharacterReturnsUTF8() {
        let event = makeKeyEvent(keyCode: 0, characters: "中")!
        let data = handler.handleKeyDown(event)
        XCTAssertEqual(data, "中".data(using: .utf8))
    }

    // MARK: - Mouse Events

    // Tests use `encodeMouseReport(type:pressButtonNumber:col:row:)` directly
    // because synthetic `NSEvent.mouseEvent` always reports `buttonNumber == 0`
    // regardless of the event type — making it impossible to exercise the
    // right/middle button paths through the NSEvent shim.

    func testMousePressLeftEncodesAsZero() {
        let data = handler.encodeMouseReport(type: .press, pressButtonNumber: 0, col: 5, row: 10)
        // ESC [ < 0 ; 6 ; 11 M  (1-based coordinates)
        XCTAssertEqual(data, "\u{1B}[<0;6;11M".data(using: .utf8))
    }

    func testMousePressRightMapsToTwo() {
        let data = handler.encodeMouseReport(type: .press, pressButtonNumber: 1, col: 5, row: 10)
        XCTAssertEqual(data, "\u{1B}[<2;6;11M".data(using: .utf8))
    }

    func testMousePressMiddleMapsToOne() {
        let data = handler.encodeMouseReport(type: .press, pressButtonNumber: 2, col: 5, row: 10)
        XCTAssertEqual(data, "\u{1B}[<1;6;11M".data(using: .utf8))
    }

    func testMousePressUnknownButtonReturnsNil() {
        let data = handler.encodeMouseReport(type: .press, pressButtonNumber: 7, col: 5, row: 10)
        XCTAssertNil(data, "unmapped buttons should be dropped, not encoded")
    }

    func testMouseReleaseUsesPressedButtonId() {
        // Right press → release must encode the same id (2), not fall back to 0.
        _ = handler.encodeMouseReport(type: .press, pressButtonNumber: 1, col: 5, row: 10)

        let data = handler.encodeMouseReport(type: .release, col: 5, row: 10)
        XCTAssertEqual(data, "\u{1B}[<2;6;11m".data(using: .utf8),
                       "release must encode the button id from the matching press")
    }

    func testMouseReleaseWithoutPriorPressFallsBackToZero() {
        // Defensive: if release arrives without a tracked press (e.g. focus
        // changed mid-drag), encode 0 rather than dropping the event.
        let data = handler.encodeMouseReport(type: .release, col: 5, row: 10)
        XCTAssertEqual(data, "\u{1B}[<0;6;11m".data(using: .utf8))
    }

    func testMouseReleaseClearsPressedButton() {
        _ = handler.encodeMouseReport(type: .press, pressButtonNumber: 1, col: 0, row: 0)
        _ = handler.encodeMouseReport(type: .release, col: 0, row: 0)

        // Second release with no press in between should fall back to 0.
        let data = handler.encodeMouseReport(type: .release, col: 5, row: 10)
        XCTAssertEqual(data, "\u{1B}[<0;6;11m".data(using: .utf8),
                       "release must clear the tracked button so a stale id isn't reused")
    }

    func testMouseDragLeftEncodesButtonPlus32() {
        _ = handler.encodeMouseReport(type: .press, pressButtonNumber: 0, col: 0, row: 0)
        let data = handler.encodeMouseReport(type: .drag, col: 3, row: 7)
        // 0 (left) + 32 = 32
        XCTAssertEqual(data, "\u{1B}[<32;4;8M".data(using: .utf8))
    }

    func testMouseDragRightEncodesButtonPlus32() {
        _ = handler.encodeMouseReport(type: .press, pressButtonNumber: 1, col: 0, row: 0)
        let data = handler.encodeMouseReport(type: .drag, col: 3, row: 7)
        // 2 (right) + 32 = 34
        XCTAssertEqual(data, "\u{1B}[<34;4;8M".data(using: .utf8))
    }

    func testMouseMoveEncodesAs35() {
        let data = handler.encodeMouseReport(type: .move, col: 3, row: 7)
        // No-button motion: 3 + 32 = 35.
        XCTAssertEqual(data, "\u{1B}[<35;4;8M".data(using: .utf8))
    }
}
