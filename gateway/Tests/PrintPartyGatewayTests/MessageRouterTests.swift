//
//  MessageRouterTests.swift
//  printparty-gateway
//
//  Tests for MessageRouter: unknown method handling and health response.
//

import XCTest
import Crypto
import NIOPosix
import PrintPartyKit
@testable import PrintPartyGateway

final class MessageRouterTests: XCTestCase {

    // MARK: - Unknown method

    func testUnknownMethodReturnsErrorEnvelope() async throws {
        let router = MessageRouter(
            gatewayId: "test-gw",
            gatewayName: "Test Gateway",
            relayURL: nil,
            logger: .init(label: "test")
        )

        let requestPayload = Data("{}".utf8)
        let request = MessageEnvelope(
            type: .request,
            id: "req-1",
            method: "nonexistent.method",
            deviceId: nil,
            payload: requestPayload.base64EncodedString()
        )

        // We need a minimal PrinterService to pass in. Since we're testing
        // unknown method, it won't actually call PrinterService.
        // Use NIOCore's MultiThreadedEventLoopGroup for the test.
        let elg = MultiThreadedEventLoopGroup.singleton
        let printerService = PrinterService(
            eventLoopGroup: elg,
            logger: .init(label: "test")
        )

        let response = await router.route(envelope: request, printerService: printerService)

        XCTAssertEqual(response.type, .error)
        XCTAssertEqual(response.id, "req-1")
        XCTAssertEqual(response.method, "nonexistent.method")

        // Decode the error payload.
        struct ErrorPayload: Decodable {
            let code: String
            let message: String
        }
        let errorPayload = response.decodePayload(ErrorPayload.self)
        XCTAssertNotNil(errorPayload)
        XCTAssertEqual(errorPayload?.code, "unknown_method")
    }

    // MARK: - Health method

    func testHealthMethodReturnsExpectedFields() async throws {
        let router = MessageRouter(
            gatewayId: "test-gw-id",
            gatewayName: "Test Gateway Name",
            relayURL: "https://relay.example.com",
            logger: .init(label: "test")
        )

        let requestPayload = Data("{}".utf8)
        let request = MessageEnvelope(
            type: .request,
            id: "req-health",
            method: "health",
            deviceId: nil,
            payload: requestPayload.base64EncodedString()
        )

        let elg = MultiThreadedEventLoopGroup.singleton
        let printerService = PrinterService(
            eventLoopGroup: elg,
            logger: .init(label: "test")
        )

        let response = await router.route(envelope: request, printerService: printerService)

        XCTAssertEqual(response.type, .response)
        XCTAssertEqual(response.id, "req-health")
        XCTAssertEqual(response.method, "health")

        // Decode the health payload.
        struct HealthPayload: Decodable {
            let status: String
            let version: String
            let gatewayId: String
            let gatewayName: String
            let relayURL: String?
            let printers: [PrinterHealth]

            struct PrinterHealth: Decodable {
                let id: UUID
                let displayName: String
                let stage: String
            }
        }

        let healthPayload = response.decodePayload(HealthPayload.self)
        XCTAssertNotNil(healthPayload)
        XCTAssertEqual(healthPayload?.status, "ok")
        XCTAssertEqual(healthPayload?.version, "0.1.0")
        XCTAssertEqual(healthPayload?.gatewayId, "test-gw-id")
        XCTAssertEqual(healthPayload?.gatewayName, "Test Gateway Name")
        XCTAssertEqual(healthPayload?.relayURL, "https://relay.example.com")
        XCTAssertEqual(healthPayload?.printers.count, 0, "No printers registered in test")
    }

    // MARK: - Invalid type

    func testNonRequestTypeReturnsError() async throws {
        let router = MessageRouter(
            gatewayId: "test-gw",
            gatewayName: "Test",
            relayURL: nil,
            logger: .init(label: "test")
        )

        let eventEnvelope = MessageEnvelope.event(method: "stream.state", payload: Data("{}".utf8))

        let elg = MultiThreadedEventLoopGroup.singleton
        let printerService = PrinterService(
            eventLoopGroup: elg,
            logger: .init(label: "test")
        )

        let response = await router.route(envelope: eventEnvelope, printerService: printerService)
        XCTAssertEqual(response.type, .error)

        struct ErrorPayload: Decodable {
            let code: String
        }
        let errorPayload = response.decodePayload(ErrorPayload.self)
        XCTAssertEqual(errorPayload?.code, "invalid_type")
    }
}
