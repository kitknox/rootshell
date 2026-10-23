import XCTest

final class EdgeSidebarAssignmentTests: XCTestCase {
    func testStockAssignment() {
        let assignment = EdgeSidebarAssignment.decode(EdgeSidebarAssignment.stock.storedTokens)
        XCTAssertEqual(assignment, .stock)
        XCTAssertEqual(assignment.side(of: .tabSwitcher), .leading)
        XCTAssertEqual(assignment.side(of: .fileManager), .trailing)
        XCTAssertEqual(assignment.pages(on: .leading), [.tabSwitcher])
        XCTAssertEqual(assignment.pages(on: .trailing), [.fileManager])
    }

    func testBothPagesOnOneSide() {
        let assignment = EdgeSidebarAssignment.decode([
            "fileManager:leading",
            "tabSwitcher:leading",
        ])
        XCTAssertEqual(assignment.pages(on: .leading), [.tabSwitcher, .fileManager])
        XCTAssertTrue(assignment.pages(on: .trailing).isEmpty)
        XCTAssertTrue(assignment.sharesOneSide)
    }

    func testBrokenStoredValueFallsBackToStock() {
        XCTAssertEqual(EdgeSidebarAssignment.decode(["tabSwitcher:leading", "tabSwitcher:trailing", "fileManager:trailing"]), .stock)
        XCTAssertEqual(EdgeSidebarAssignment.decode(["tabSwitcher:leading"]), .stock)
        XCTAssertEqual(EdgeSidebarAssignment.decode(["tabSwitcher:leading", "fileManager:middle"]), .stock)
        XCTAssertEqual(EdgeSidebarAssignment.decode([]), .stock)
    }
}
