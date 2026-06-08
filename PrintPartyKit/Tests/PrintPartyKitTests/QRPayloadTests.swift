//
//  QRPayloadTests.swift
//  PrintPartyKit
//
//  Tests for PairingDeepLink — the shared parser for the QR / `printparty://`
//  pairing payload: printparty://pair?url=<enc>&code=<8-char-code>
//

import XCTest
@testable import PrintPartyKit

final class QRPayloadTests: XCTestCase {

    func testValidPayloadParses() {
        let payload = PairingDeepLink.parse(
            "printparty://pair?url=http%3A%2F%2F192.168.1.42%3A8080&code=AB3KX7YZ"
        )
        XCTAssertEqual(payload?.url, "http://192.168.1.42:8080")
        XCTAssertEqual(payload?.code, "AB3KX7YZ")
    }

    func testMissingURLReturnsNil() {
        XCTAssertNil(PairingDeepLink.parse("printparty://pair?code=AB3KX7YZ"))
    }

    func testMissingCodeReturnsNil() {
        XCTAssertNil(PairingDeepLink.parse("printparty://pair?url=http%3A%2F%2F192.168.1.42%3A8080"))
    }

    func testWrongSchemeReturnsNil() {
        XCTAssertNil(PairingDeepLink.parse("http://pair?url=http%3A%2F%2Fx&code=AB3KX7YZ"))
    }

    func testWrongHostReturnsNil() {
        XCTAssertNil(PairingDeepLink.parse("printparty://connect?url=http%3A%2F%2Fx&code=AB3KX7YZ"))
    }

    func testEmptyParametersReturnNil() {
        XCTAssertNil(PairingDeepLink.parse("printparty://pair?url=&code="))
    }

    func testPercentEncodedSpecialCharactersDecode() {
        // Host with a path + query-ish characters that were percent-encoded.
        let raw = "http://gw.local:8080/base?x=1"
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let payload = PairingDeepLink.parse("printparty://pair?url=\(encoded)&code=AB3KX7YZ")
        XCTAssertEqual(payload?.url, raw)
    }

    func testLowercaseCodeIsUppercased() {
        let payload = PairingDeepLink.parse(
            "printparty://pair?url=http%3A%2F%2F192.168.1.42%3A8080&code=ab3kx7yz"
        )
        XCTAssertEqual(payload?.code, "AB3KX7YZ")
    }

    func testUppercaseSchemeIsAccepted() {
        let payload = PairingDeepLink.parse(
            "PRINTPARTY://pair?url=http%3A%2F%2F192.168.1.42%3A8080&code=AB3KX7YZ"
        )
        XCTAssertEqual(payload?.url, "http://192.168.1.42:8080")
    }

    func testParseFromURL() {
        let url = URL(string: "printparty://pair?url=http%3A%2F%2F10.0.0.5%3A9000&code=ZZ11ZZ11")!
        let payload = PairingDeepLink.parse(url)
        XCTAssertEqual(payload?.url, "http://10.0.0.5:9000")
        XCTAssertEqual(payload?.code, "ZZ11ZZ11")
    }
}
