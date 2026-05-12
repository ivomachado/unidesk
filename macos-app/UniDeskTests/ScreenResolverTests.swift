import XCTest
@testable import UniDesk

final class ScreenResolverTests: XCTestCase {

    // MARK: - isViewFinityS9

    func testViewFinityNameMatches() {
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "ViewFinity S9"))
    }

    func testS27C9PatternMatches() {
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "S27C900P"))
    }

    func testS32C9PatternMatches() {
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "S32C900NA"))
    }

    func testS27CMPatternMatches() {
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "S27CM500EE"))
    }

    func testS32CMPatternMatches() {
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "S32CM703UN"))
    }

    func testLS27CPatternMatches() {
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "LS27C900VNNXZA"))
    }

    func testLS32CPatternMatches() {
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "LS32C900VNNXZA"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "viewfinity"))
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "s32cm"))
        XCTAssertTrue(ScreenResolver.isViewFinityS9(name: "S27C9"))
    }

    func testNonViewFinityDisplayDoesNotMatch() {
        XCTAssertFalse(ScreenResolver.isViewFinityS9(name: "Dell P2715Q"))
        XCTAssertFalse(ScreenResolver.isViewFinityS9(name: "LG UltraFine 5K"))
        XCTAssertFalse(ScreenResolver.isViewFinityS9(name: "DELL U2722D"))
        XCTAssertFalse(ScreenResolver.isViewFinityS9(name: "Pro Display XDR"))
    }

    func testEmptyNameDoesNotMatch() {
        XCTAssertFalse(ScreenResolver.isViewFinityS9(name: ""))
    }

    // MARK: - encode / decode round-trip

    func testEncodeDecodeRoundTrip() {
        let cases: [ScreenType] = [.builtIn, .compatible, .viewFinityS9, .unsupported]
        for type in cases {
            let encoded = ScreenResolver.encode(type)
            let decoded = ScreenResolver.decode(encoded)
            XCTAssertEqual(decoded, type, "Round-trip failed for \(type)")
        }
    }

    func testDecodeUnknownStringReturnsNil() {
        XCTAssertNil(ScreenResolver.decode("totally_unknown"))
        XCTAssertNil(ScreenResolver.decode(""))
        XCTAssertNil(ScreenResolver.decode("ViewFinityS9")) // wrong capitalisation
    }

    func testEncodeValues() {
        XCTAssertEqual(ScreenResolver.encode(.builtIn),      "builtIn")
        XCTAssertEqual(ScreenResolver.encode(.compatible),   "compatible")
        XCTAssertEqual(ScreenResolver.encode(.viewFinityS9), "viewFinityS9")
        XCTAssertEqual(ScreenResolver.encode(.unsupported),  "unsupported")
    }
}
