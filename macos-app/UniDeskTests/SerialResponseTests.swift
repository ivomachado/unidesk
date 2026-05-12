import XCTest
@testable import UniDesk

final class SerialResponseTests: XCTestCase {

    // MARK: - OK responses

    func testOkPingWithNonce() {
        let r = SerialResponse.parse("OK:PING:ab12")
        XCTAssertEqual(r?.okPayload, "PING:ab12")
    }

    func testOkPingWithoutNonce() {
        let r = SerialResponse.parse("OK:PING")
        XCTAssertEqual(r?.okPayload, "PING")
    }

    func testOkPairing() {
        let r = SerialResponse.parse("OK:PAIRING")
        XCTAssertEqual(r?.okPayload, "PAIRING")
    }

    func testOkUnpaired() {
        let r = SerialResponse.parse("OK:UNPAIRED")
        XCTAssertEqual(r?.okPayload, "UNPAIRED")
    }

    func testOkEscDebounce() {
        let r = SerialResponse.parse("OK:ESC_DEBOUNCE:2000")
        XCTAssertEqual(r?.okPayload, "ESC_DEBOUNCE:2000")
    }

    // MARK: - STATUS responses

    func testStatusConnected() {
        let r = SerialResponse.parse("STATUS:connected:MacBook Pro")
        guard case .status(let connected, let name) = r else {
            return XCTFail("Expected .status, got \(String(describing: r))")
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(name, "MacBook Pro")
    }

    func testStatusDisconnected() {
        let r = SerialResponse.parse("STATUS:disconnected:")
        guard case .status(let connected, let name) = r else {
            return XCTFail("Expected .status, got \(String(describing: r))")
        }
        XCTAssertFalse(connected)
        XCTAssertEqual(name, "")
    }

    func testStatusDeviceNameWithColon() {
        // maxSplits: 1 means the device name can itself contain colons
        let r = SerialResponse.parse("STATUS:connected:Bose:QC45")
        guard case .status(let connected, let name) = r else {
            return XCTFail("Expected .status, got \(String(describing: r))")
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(name, "Bose:QC45")
    }

    func testStatusNoDeviceName() {
        let r = SerialResponse.parse("STATUS:connected")
        guard case .status(let connected, let name) = r else {
            return XCTFail("Expected .status, got \(String(describing: r))")
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(name, "")
    }

    // MARK: - ERR responses

    func testErrTimeout() {
        let r = SerialResponse.parse("ERR:TIMEOUT")
        guard case .error(let msg) = r else {
            return XCTFail("Expected .error, got \(String(describing: r))")
        }
        XCTAssertEqual(msg, "TIMEOUT")
    }

    func testErrUnknownCmd() {
        let r = SerialResponse.parse("ERR:UNKNOWN_CMD")
        guard case .error(let msg) = r else {
            return XCTFail("Expected .error, got \(String(describing: r))")
        }
        XCTAssertEqual(msg, "UNKNOWN_CMD")
    }

    // MARK: - Trimming

    func testTrailingNewlineIsTrimmed() {
        let r = SerialResponse.parse("OK:PAIRING\n")
        XCTAssertEqual(r?.okPayload, "PAIRING")
    }

    func testLeadingAndTrailingWhitespaceIsTrimmed() {
        let r = SerialResponse.parse("  OK:PAIRING  ")
        XCTAssertEqual(r?.okPayload, "PAIRING")
    }

    // MARK: - Unparseable

    func testEmptyStringReturnsNil() {
        XCTAssertNil(SerialResponse.parse(""))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(SerialResponse.parse("   "))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(SerialResponse.parse("not a protocol line"))
    }

    func testPartialPrefixReturnsNil() {
        XCTAssertNil(SerialResponse.parse("OK"))   // no colon
        XCTAssertNil(SerialResponse.parse("STATUS"))
        XCTAssertNil(SerialResponse.parse("ERR"))
    }
}
