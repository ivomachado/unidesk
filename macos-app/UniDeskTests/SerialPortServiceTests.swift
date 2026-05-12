import XCTest
@testable import UniDesk

// SerialPortService and responseMatchesExpected are @MainActor-isolated.
@MainActor
final class SerialPortServiceTests: XCTestCase {

    // MARK: - parseEscDebounceResponse (static)

    func testParseValidEscDebounceResponse() {
        XCTAssertEqual(SerialPortService.parseEscDebounceResponse(.ok("ESC_DEBOUNCE:2000")), 2000)
    }

    func testParseEscDebounceMin() {
        XCTAssertEqual(SerialPortService.parseEscDebounceResponse(.ok("ESC_DEBOUNCE:200")), 200)
    }

    func testParseEscDebounceMax() {
        XCTAssertEqual(SerialPortService.parseEscDebounceResponse(.ok("ESC_DEBOUNCE:10000")), 10000)
    }

    func testParseEscDebounceEmptyValue() {
        XCTAssertNil(SerialPortService.parseEscDebounceResponse(.ok("ESC_DEBOUNCE:")))
    }

    func testParseEscDebounceNonNumericValue() {
        XCTAssertNil(SerialPortService.parseEscDebounceResponse(.ok("ESC_DEBOUNCE:abc")))
    }

    func testParseEscDebounceWrongOkPayload() {
        XCTAssertNil(SerialPortService.parseEscDebounceResponse(.ok("PAIRING")))
    }

    func testParseEscDebounceFromError() {
        XCTAssertNil(SerialPortService.parseEscDebounceResponse(.error("TIMEOUT")))
    }

    func testParseEscDebounceFromStatus() {
        XCTAssertNil(SerialPortService.parseEscDebounceResponse(.status(connected: true, deviceName: "X")))
    }

    // MARK: - responseMatchesExpected (instance, nonce-aware)

    func testPingResponseMatchesNonce() {
        let svc = SerialPortService()
        svc.handshakeNonce = "ab12"
        XCTAssertTrue(svc.responseMatchesExpected(.ok("PING:ab12"), tag: "PING:ab12"))
    }

    func testPingResponseDoesNotMatchWrongNonce() {
        let svc = SerialPortService()
        svc.handshakeNonce = "ab12"
        XCTAssertFalse(svc.responseMatchesExpected(.ok("PING:ffff"), tag: "PING:ab12"))
    }

    func testExactTagMatch() {
        let svc = SerialPortService()
        XCTAssertTrue(svc.responseMatchesExpected(.ok("PAIRING"),  tag: "PAIRING"))
        XCTAssertTrue(svc.responseMatchesExpected(.ok("UNPAIRED"), tag: "UNPAIRED"))
    }

    func testPrefixTagMatchForEscDebounce() {
        let svc = SerialPortService()
        XCTAssertTrue(svc.responseMatchesExpected(.ok("ESC_DEBOUNCE:2000"), tag: "ESC_DEBOUNCE"))
        XCTAssertTrue(svc.responseMatchesExpected(.ok("ESC_DEBOUNCE:500"),  tag: "ESC_DEBOUNCE"))
    }

    func testTagMismatch() {
        let svc = SerialPortService()
        XCTAssertFalse(svc.responseMatchesExpected(.ok("PAIRING"),          tag: "UNPAIRED"))
        XCTAssertFalse(svc.responseMatchesExpected(.ok("ESC_DEBOUNCE:2000"), tag: "PAIRING"))
    }

    func testStatusResponseMatchesStatusTag() {
        let svc = SerialPortService()
        XCTAssertTrue(svc.responseMatchesExpected(.status(connected: true, deviceName: "X"), tag: "STATUS"))
    }

    func testStatusResponseDoesNotMatchNonStatusTag() {
        let svc = SerialPortService()
        XCTAssertFalse(svc.responseMatchesExpected(.status(connected: true, deviceName: "X"), tag: "PAIRING"))
    }

    func testErrorAlwaysMatches() {
        // Errors are always delivered regardless of tag so the caller sees the failure.
        let svc = SerialPortService()
        XCTAssertTrue(svc.responseMatchesExpected(.error("TIMEOUT"),           tag: "PAIRING"))
        XCTAssertTrue(svc.responseMatchesExpected(.error("UNKNOWN_CMD"),       tag: "STATUS"))
        XCTAssertTrue(svc.responseMatchesExpected(.error("NVS_WRITE_FAILED"),  tag: "ESC_DEBOUNCE"))
    }
}
