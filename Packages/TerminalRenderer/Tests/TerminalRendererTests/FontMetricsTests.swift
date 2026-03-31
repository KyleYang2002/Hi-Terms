import XCTest
@testable import TerminalRenderer

final class FontMetricsTests: XCTestCase {
    func testMeasureMenlo() {
        let font = NSFont(name: "Menlo", size: 13)!
        let metrics = FontMetrics.measure(font: font)
        XCTAssertGreaterThan(metrics.cellWidth, 0)
        XCTAssertGreaterThan(metrics.cellHeight, 0)
        XCTAssertGreaterThan(metrics.baseline, 0)
        XCTAssertTrue(metrics.fontName.contains("Menlo"))
        XCTAssertEqual(metrics.fontSize, 13)
    }
}
