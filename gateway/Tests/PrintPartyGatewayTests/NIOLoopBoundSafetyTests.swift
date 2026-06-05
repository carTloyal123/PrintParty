//
//  NIOLoopBoundSafetyTests.swift
//  printparty-gateway
//
//  Tests that verify envelope encoding/decoding, broadcast state formatting,
//  and error envelope correctness — the data contracts that WebSocket clients
//  (iOS, relay) depend on.
//

import XCTest
@testable import PrintPartyGateway

final class NIOLoopBoundSafetyTests: XCTestCase {

    // MARK: - MessageEnvelope round-trip

    func testMessageEnvelopeRoundTrip() throws {
        let state = PrintJobState.idle(
            printerId: UUID(),
            displayName: "Test Printer",
            model: "X1C"
        )
        let payloadData = try JSONEncoder().encode(state)
        let envelope = MessageEnvelope.event(method: "stream.state", payload: payloadData)

        // Encode → Decode round-trip
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(MessageEnvelope.self, from: encoded)

        XCTAssertEqual(decoded.type, .event)
        XCTAssertEqual(decoded.method, "stream.state")
        XCTAssertNil(decoded.id)
        XCTAssertNil(decoded.deviceId)
        XCTAssertEqual(decoded.payload, envelope.payload)

        // Verify the inner payload decodes back to the original state
        let recoveredState = decoded.decodePayload(PrintJobState.self)
        XCTAssertNotNil(recoveredState)
        XCTAssertEqual(recoveredState?.printerId, state.printerId)
        XCTAssertEqual(recoveredState?.printerDisplayName, "Test Printer")
        XCTAssertEqual(recoveredState?.printerModel, "X1C")
        XCTAssertEqual(recoveredState?.stage, .idle)
    }

    // MARK: - Broadcast state produces valid envelope JSON

    func testBroadcastStateEnvelopeFormat() throws {
        let printerId = UUID()
        var state = PrintJobState(
            printerId: printerId,
            printerDisplayName: "Bambu X1C",
            printerModel: "X1C",
            stage: .printing
        )
        state.progressPercent = 42.5
        state.currentLayer = 10
        state.totalLayers = 200
        state.jobName = "benchy.gcode"

        let payloadData = try JSONEncoder().encode(state)
        let envelope = MessageEnvelope.event(method: "stream.state", payload: payloadData)
        let envData = try JSONEncoder().encode(envelope)
        let envJson = String(data: envData, encoding: .utf8)!

        // Parse the top-level JSON to verify structure
        let topLevel = try JSONSerialization.jsonObject(with: envData) as! [String: Any]
        XCTAssertEqual(topLevel["type"] as? String, "event")
        XCTAssertEqual(topLevel["method"] as? String, "stream.state")
        XCTAssertNil(topLevel["id"], "Events must not have an id")
        XCTAssertNotNil(topLevel["payload"] as? String, "Payload must be a base64 string")

        // Verify payload is valid base64 that decodes to valid JSON
        let base64Payload = topLevel["payload"] as! String
        let decodedPayload = Data(base64Encoded: base64Payload)!
        let payloadObj = try JSONSerialization.jsonObject(with: decodedPayload) as! [String: Any]

        XCTAssertEqual(payloadObj["printerId"] as? String, printerId.uuidString.uppercased())
        XCTAssertEqual(payloadObj["printerDisplayName"] as? String, "Bambu X1C")
        XCTAssertEqual(payloadObj["stage"] as? String, "printing")
        XCTAssertEqual(payloadObj["progressPercent"] as? Double, 42.5)
        XCTAssertEqual(payloadObj["jobName"] as? String, "benchy.gcode")

        // Verify it's valid UTF-8 JSON (what ws.send receives)
        XCTAssertFalse(envJson.isEmpty)
    }

    // MARK: - Envelope matches iOS client expectations

    func testEnvelopeMatchesIOSClientContract() throws {
        // iOS clients expect: { "type": "event", "method": "stream.state",
        //                        "payload": "<base64>" }
        // with payload decoding to a PrintJobState with at minimum:
        // printerId, printerDisplayName, printerModel, stage, progressPercent, updatedAt

        let state = PrintJobState.idle(
            printerId: UUID(),
            displayName: "My Printer",
            model: "P1S"
        )
        let payloadData = try JSONEncoder().encode(state)
        let envelope = MessageEnvelope.event(method: "stream.state", payload: payloadData)
        let envData = try JSONEncoder().encode(envelope)

        // Decode as the iOS client would
        let topLevel = try JSONDecoder().decode(MessageEnvelope.self, from: envData)
        XCTAssertEqual(topLevel.type, .event)
        XCTAssertEqual(topLevel.method, "stream.state")

        // Decode inner payload
        let innerData = topLevel.payloadData()
        XCTAssertNotNil(innerData)

        let innerJSON = try JSONSerialization.jsonObject(with: innerData!) as! [String: Any]

        // These keys MUST be present for iOS clients
        let requiredKeys = ["printerId", "printerDisplayName", "printerModel", "stage", "progressPercent", "updatedAt"]
        for key in requiredKeys {
            XCTAssertNotNil(innerJSON[key], "Required key '\(key)' missing from PrintJobState payload")
        }
    }

    // MARK: - Error envelopes

    func testErrorEnvelopeIsCorrectlyFormed() throws {
        let envelope = MessageEnvelope.error(
            id: "req-789",
            method: "printers.command",
            code: "printer_not_found",
            message: "No printer with that ID"
        )

        XCTAssertEqual(envelope.type, .error)
        XCTAssertEqual(envelope.id, "req-789")
        XCTAssertEqual(envelope.method, "printers.command")

        // Encode to JSON and verify structure
        let envData = try JSONEncoder().encode(envelope)
        let topLevel = try JSONSerialization.jsonObject(with: envData) as! [String: Any]
        XCTAssertEqual(topLevel["type"] as? String, "error")
        XCTAssertEqual(topLevel["id"] as? String, "req-789")

        // Decode the error payload
        struct ErrorPayload: Decodable {
            let code: String
            let message: String
        }
        let errorPayload = envelope.decodePayload(ErrorPayload.self)
        XCTAssertNotNil(errorPayload)
        XCTAssertEqual(errorPayload?.code, "printer_not_found")
        XCTAssertEqual(errorPayload?.message, "No printer with that ID")
    }

    func testErrorEnvelopeWithEmptyIdStillValid() throws {
        let envelope = MessageEnvelope.error(
            id: "",
            method: "unknown",
            code: "unknown_method",
            message: "Unrecognized method"
        )

        let envData = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(MessageEnvelope.self, from: envData)

        XCTAssertEqual(decoded.type, .error)
        XCTAssertEqual(decoded.id, "")
        XCTAssertEqual(decoded.method, "unknown")
    }

    // MARK: - Multiple states produce independent envelopes

    func testMultipleStatesProduceIndependentEnvelopes() throws {
        let states = [
            PrintJobState.idle(printerId: UUID(), displayName: "Printer A", model: "X1C"),
            PrintJobState.idle(printerId: UUID(), displayName: "Printer B", model: "P1S"),
        ]

        let envelopes = try states.map { state -> MessageEnvelope in
            let data = try JSONEncoder().encode(state)
            return MessageEnvelope.event(method: "stream.state", payload: data)
        }

        // Each envelope should have a different payload
        XCTAssertNotEqual(envelopes[0].payload, envelopes[1].payload)

        // But same structure
        for env in envelopes {
            XCTAssertEqual(env.type, .event)
            XCTAssertEqual(env.method, "stream.state")
            XCTAssertNil(env.id)
        }
    }
}
