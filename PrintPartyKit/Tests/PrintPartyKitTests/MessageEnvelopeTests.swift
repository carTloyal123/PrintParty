//
//  MessageEnvelopeTests.swift
//  PrintPartyKit
//
//  Tests for MessageEnvelope model: factories, JSON round-trip, payload encoding.
//

import XCTest
@testable import PrintPartyKit

final class MessageEnvelopeTests: XCTestCase {

    // MARK: - Factory: event

    func testEventFactoryCreatesCorrectTypeAndMethod() {
        let payload = Data("{\"key\":\"value\"}".utf8)
        let envelope = MessageEnvelope.event(method: "stream.state", payload: payload)

        XCTAssertEqual(envelope.type, .event)
        XCTAssertEqual(envelope.method, "stream.state")
        XCTAssertNil(envelope.id, "Events should have no id")
        XCTAssertNil(envelope.deviceId, "Events should have no deviceId")
    }

    // MARK: - Factory: response

    func testResponseFactoryEchoesId() {
        let payload = Data("{\"status\":\"ok\"}".utf8)
        let envelope = MessageEnvelope.response(id: "req-123", method: "health", payload: payload)

        XCTAssertEqual(envelope.type, .response)
        XCTAssertEqual(envelope.id, "req-123")
        XCTAssertEqual(envelope.method, "health")
    }

    // MARK: - Factory: error

    func testErrorFactoryStructure() {
        let envelope = MessageEnvelope.error(
            id: "req-456",
            method: "printers.list",
            code: "unknown_method",
            message: "Method not found"
        )

        XCTAssertEqual(envelope.type, .error)
        XCTAssertEqual(envelope.id, "req-456")
        XCTAssertEqual(envelope.method, "printers.list")

        // Decode the error payload.
        struct ErrorPayload: Decodable {
            let code: String
            let message: String
        }
        let decoded = envelope.decodePayload(ErrorPayload.self)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.code, "unknown_method")
        XCTAssertEqual(decoded?.message, "Method not found")
    }

    // MARK: - JSON round-trip

    func testJSONEncodeDecodeRoundTrip() throws {
        let payload = Data("{\"foo\":42}".utf8)
        let original = MessageEnvelope(
            type: .request,
            id: "abc-def",
            method: "printers.state",
            deviceId: "device-001",
            payload: payload.base64EncodedString()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)

        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.method, original.method)
        XCTAssertEqual(decoded.deviceId, original.deviceId)
        XCTAssertEqual(decoded.payload, original.payload)
    }

    // MARK: - Payload is base64-encoded

    func testPayloadIsBase64Encoded() throws {
        let rawPayload = Data("{\"printerId\":\"123\"}".utf8)
        let envelope = MessageEnvelope.event(method: "stream.state", payload: rawPayload)

        // The payload field should be a valid base64 string.
        let expectedBase64 = rawPayload.base64EncodedString()
        XCTAssertEqual(envelope.payload, expectedBase64)

        // Decoding the base64 should give back the original data.
        let decoded = Data(base64Encoded: envelope.payload)
        XCTAssertEqual(decoded, rawPayload)
    }

    func testPayloadDataHelper() {
        let rawPayload = Data("test-data".utf8)
        let envelope = MessageEnvelope.event(method: "test", payload: rawPayload)

        let recovered = envelope.payloadData()
        XCTAssertEqual(recovered, rawPayload)
    }

    func testDecodePayloadHelper() {
        struct TestPayload: Codable, Equatable {
            let name: String
            let count: Int
        }
        let original = TestPayload(name: "hello", count: 42)
        let payloadData = try! JSONEncoder().encode(original)
        let envelope = MessageEnvelope.response(id: "1", method: "test", payload: payloadData)

        let decoded = envelope.decodePayload(TestPayload.self)
        XCTAssertEqual(decoded, original)
    }
}
