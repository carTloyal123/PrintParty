//
//  GatewayDiscoveryPresenterTests.swift
//  PrintPartyKit
//
//  Tests the pure presentation logic behind DiscoveredGatewayList: which state
//  the list shows, and whether a discovered gateway is selectable. This stands
//  in for an NWBrowser mock — the view renders exactly what these functions
//  decide, so asserting them covers the list's behavior without a UI target.
//

import XCTest
@testable import PrintPartyKit

final class GatewayDiscoveryPresenterTests: XCTestCase {

    func testScanningWhenBrowsingWithNoResults() {
        XCTAssertEqual(
            GatewayDiscoveryPresenter.listState(discoveredCount: 0, isBrowsing: true),
            .scanning
        )
    }

    func testEmptyWhenNotBrowsingWithNoResults() {
        XCTAssertEqual(
            GatewayDiscoveryPresenter.listState(discoveredCount: 0, isBrowsing: false),
            .empty
        )
    }

    func testPopulatedWhenResultsArrive() {
        XCTAssertEqual(
            GatewayDiscoveryPresenter.listState(discoveredCount: 2, isBrowsing: true),
            .populated
        )
        // Still populated even after browsing stops.
        XCTAssertEqual(
            GatewayDiscoveryPresenter.listState(discoveredCount: 2, isBrowsing: false),
            .populated
        )
    }

    func testUnpairedGatewayIsSelectable() {
        XCTAssertTrue(
            GatewayDiscoveryPresenter.isSelectable(gatewayId: "a3f7c2e1", pairedIds: ["deadbeef"])
        )
    }

    func testPairedGatewayIsNotSelectable() {
        XCTAssertFalse(
            GatewayDiscoveryPresenter.isSelectable(gatewayId: "a3f7c2e1", pairedIds: ["a3f7c2e1"])
        )
    }
}
