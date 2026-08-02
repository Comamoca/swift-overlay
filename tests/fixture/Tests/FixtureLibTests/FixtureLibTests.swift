import XCTest
@testable import FixtureLib

final class FixtureLibTests: XCTestCase {
    func testGreeting() {
        XCTAssertTrue(fixtureGreeting().hasPrefix("fixture-ok"))
    }
}
