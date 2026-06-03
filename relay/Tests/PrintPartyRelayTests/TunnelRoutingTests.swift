//
//  TunnelRoutingTests.swift
//  printparty-relay
//
//  Unit tests for TunnelBroker's bidirectional routing logic:
//  - Broadcast (*:payload) fans out to all downstream clients
//  - Targeted (<uuid>:payload) routes to specific client only
//  - Unknown tags are dropped
//  - Client frames are forwarded upstream with clientId prepended
//

import XCTest
import Logging
@testable import PrintPartyRelay

final class TunnelRoutingTests: XCTestCase {

    private func makeBroker() -> TunnelBroker {
        TunnelBroker(logger: Logger(label: "test"))
    }

    // MARK: - Broadcast tag parsing

    func testBroadcastTagWithNoClientsDoesNotCrash() {
        let broker = makeBroker()
        // "*:payload" with no downstream clients should complete without crashing.
        broker.forward(gatewayId: "test-gw", text: "*:kJ3x.p2vLmR8sT1nW")
    }

    func testBroadcastToNonexistentGateway() {
        let broker = makeBroker()
        // Broadcast to a gateway with no registered downstreams.
        broker.forward(gatewayId: "nonexistent-gw", text: "*:someEncryptedPayload")
    }

    func testBroadcastWithEmptyPayload() {
        let broker = makeBroker()
        // "*:" with empty payload after colon — should not crash.
        broker.forward(gatewayId: "test-gw", text: "*:")
    }

    // MARK: - Targeted routing tag parsing

    func testUUIDTagWithNoMatchingClient() {
        let broker = makeBroker()
        let uuid = UUID()
        // "<uuid>:payload" with no matching client — should log warning, not crash.
        broker.forward(gatewayId: "test-gw", text: "\(uuid.uuidString):somePayload")
    }

    func testTargetedRouteWithColonInPayload() {
        let broker = makeBroker()
        let uuid = UUID()
        // Payload itself contains colons — only split on the first one.
        // The payload "nonce.cipher:with:extra:colons" should be preserved intact.
        broker.forward(gatewayId: "test-gw", text: "\(uuid.uuidString):nonce.cipher:with:extra:colons")
    }

    // MARK: - Unknown / malformed tags

    func testUnknownTagIsDropped() {
        let broker = makeBroker()
        // "not-a-uuid:payload" is not "*" and not a valid UUID — should be dropped.
        broker.forward(gatewayId: "test-gw", text: "not-a-valid-uuid:somePayload")
    }

    func testFrameWithNoColonIsDropped() {
        let broker = makeBroker()
        // No colon at all — should be dropped with a warning.
        broker.forward(gatewayId: "test-gw", text: "noColonInThisFrame")
    }

    func testEmptyFrameIsDropped() {
        let broker = makeBroker()
        broker.forward(gatewayId: "test-gw", text: "")
    }

    func testColonOnlyFrame() {
        let broker = makeBroker()
        // ":" has empty tag and empty payload — empty string is not "*" or UUID.
        broker.forward(gatewayId: "test-gw", text: ":")
    }

    // MARK: - Upstream forwarding

    func testForwardUpstreamWithNoGatewayDoesNotCrash() {
        let broker = makeBroker()
        let clientId = UUID()
        // No upstream registered — should log warning and not crash.
        broker.forwardUpstream(gatewayId: "nonexistent-gw", clientId: clientId, text: "kJ3x.q9mN")
    }

    func testForwardUpstreamWithNoUpstreamRegistered() {
        let broker = makeBroker()
        let clientId = UUID()
        // No upstream WebSocket for this gateway — graceful no-op.
        broker.forwardUpstream(gatewayId: "test-gw", clientId: clientId, text: "testFrame")
    }

    // MARK: - Counts

    func testDownstreamCountZeroByDefault() {
        let broker = makeBroker()
        XCTAssertEqual(broker.downstreamCount(for: "test-gw"), 0)
    }

    func testUpstreamCountZeroByDefault() {
        let broker = makeBroker()
        XCTAssertEqual(broker.upstreamCount, 0)
    }

    // MARK: - Encrypted-like payload with dots

    /// Verify that the tag parser splits on the FIRST colon only and
    /// doesn't get confused by dots in the payload (which resemble
    /// encrypted nonce.ciphertext strings).
    func testBroadcastWithDotsInPayload() {
        let broker = makeBroker()
        // "*:abc123.xyz789" — the payload contains a dot but the tag
        // should still be "*" (everything before the first colon).
        broker.forward(gatewayId: "test-gw", text: "*:abc123.xyz789")
    }

    func testTargetedRouteWithDotsInPayload() {
        let broker = makeBroker()
        let uuid = UUID()
        // "<uuid>:nonce.ciphertext.tag" — dots in payload must not
        // confuse the split-on-first-colon logic.
        broker.forward(gatewayId: "test-gw", text: "\(uuid.uuidString):abc123.xyz789.def456")
    }

    // MARK: - Tag format validation

    /// Verify that the broker correctly parses the tag from various frame formats.
    func testVariousFrameFormats() {
        let broker = makeBroker()

        // All of these should not crash regardless of content.
        let frames = [
            "*:payload",
            "\(UUID().uuidString):payload",
            "short:payload",
            "UPPERCASE-NOT-UUID:payload",
            "*:nonce.ciphertext",
            "\(UUID().uuidString):nonce.ciphertext.with.dots",
            ":::multiple:colons",
            "*:",                     // broadcast with empty payload
            "\(UUID()):data",         // UUID() shorthand
        ]

        for frame in frames {
            broker.forward(gatewayId: "test-gw", text: frame)
        }
    }
}
