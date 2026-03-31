import XCTest
@testable import TerminalRenderer

final class DirtyRegionTests: XCTestCase {
    func testInitiallyEmpty() {
        let region = DirtyRegion()
        XCTAssertTrue(region.isEmpty)
    }

    func testMergeRows() {
        let region = DirtyRegion()
        region.merge(IndexSet([0, 5, 10]))
        XCTAssertFalse(region.isEmpty)
    }

    func testSwapAndClear() {
        let region = DirtyRegion()
        region.merge(IndexSet([0, 1, 2]))
        region.merge(IndexSet([5, 6]))
        let swapped = region.swapAndClear()
        XCTAssertEqual(swapped, IndexSet([0, 1, 2, 5, 6]))
        XCTAssertTrue(region.isEmpty)
    }

    func testMergeRow() {
        let region = DirtyRegion()
        region.merge(row: 3)
        let swapped = region.swapAndClear()
        XCTAssertEqual(swapped, IndexSet(integer: 3))
    }

    func testMergeRange() {
        let region = DirtyRegion()
        region.merge(rows: 0..<5)
        let swapped = region.swapAndClear()
        XCTAssertEqual(swapped, IndexSet(integersIn: 0..<5))
    }

    func testMultipleSwapsAreIndependent() {
        let region = DirtyRegion()
        region.merge(IndexSet([0, 1]))
        _ = region.swapAndClear()
        region.merge(IndexSet([2, 3]))
        let second = region.swapAndClear()
        XCTAssertEqual(second, IndexSet([2, 3]))
    }
}
