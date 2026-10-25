import XCTest

final class EdgeSidebarAssignmentTests: XCTestCase {
    func testStockAssignment() {
        let assignment = EdgeSidebarAssignment.decode(EdgeSidebarAssignment.stock.storedTokens)
        XCTAssertEqual(assignment, .stock)
        XCTAssertEqual(assignment.side(of: .tabSwitcher), .leading)
        XCTAssertEqual(assignment.side(of: .fileManager), .trailing)
        XCTAssertEqual(assignment.side(of: .httpCapture), .trailing)
        XCTAssertEqual(assignment.pages(on: .leading), [.tabSwitcher])
        XCTAssertEqual(assignment.pages(on: .trailing), EdgeSidebarPage.availableCases.filter { $0 != .tabSwitcher })
    }

    func testAllPagesOnOneSide() {
        let assignment = EdgeSidebarAssignment.decode(EdgeSidebarPage.allCases.reversed().map { "\($0.rawValue):leading" })
        XCTAssertEqual(assignment.pages(on: .leading), EdgeSidebarPage.availableCases)
        XCTAssertTrue(assignment.pages(on: .trailing).isEmpty)
    }

    func testBrokenStoredValueFallsBackToStock() {
        XCTAssertEqual(EdgeSidebarAssignment.decode(["tabSwitcher:leading", "tabSwitcher:trailing", "fileManager:trailing", "httpCapture:trailing"]), .stock)
        XCTAssertEqual(EdgeSidebarAssignment.decode(["tabSwitcher:leading"]), .stock)
        XCTAssertEqual(EdgeSidebarAssignment.decode(["tabSwitcher:leading", "fileManager:middle"]), .stock)
        XCTAssertEqual(EdgeSidebarAssignment.decode([]), .stock)
    }
}
