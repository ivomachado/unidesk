import XCTest
@testable import UniDesk

final class ScreenTypeTests: XCTestCase {

    // MARK: - supportsBrightness

    func testBuiltInSupportsBrightness() {
        XCTAssertTrue(ScreenType.builtIn.supportsBrightness)
    }

    func testCompatibleSupportsBrightness() {
        XCTAssertTrue(ScreenType.compatible.supportsBrightness)
    }

    func testViewFinityS9SupportsBrightness() {
        XCTAssertTrue(ScreenType.viewFinityS9.supportsBrightness)
    }

    func testUnsupportedDoesNotSupportBrightness() {
        XCTAssertFalse(ScreenType.unsupported.supportsBrightness)
    }

    // MARK: - usesSerialBridge

    func testViewFinityS9UsesSerialBridge() {
        XCTAssertTrue(ScreenType.viewFinityS9.usesSerialBridge)
    }

    func testBuiltInDoesNotUseSerialBridge() {
        XCTAssertFalse(ScreenType.builtIn.usesSerialBridge)
    }

    func testCompatibleDoesNotUseSerialBridge() {
        XCTAssertFalse(ScreenType.compatible.usesSerialBridge)
    }

    func testUnsupportedDoesNotUseSerialBridge() {
        XCTAssertFalse(ScreenType.unsupported.usesSerialBridge)
    }

    // MARK: - description

    func testDescriptions() {
        XCTAssertEqual(ScreenType.builtIn.description,      "Built-in Display")
        XCTAssertEqual(ScreenType.compatible.description,   "Compatible Display")
        XCTAssertEqual(ScreenType.viewFinityS9.description, "ViewFinity S9")
        XCTAssertEqual(ScreenType.unsupported.description,  "Unsupported Display")
    }
}
