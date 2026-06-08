//
//  GatewayDiscoveryPresenter.swift
//  PrintPartyKit
//
//  Pure presentation logic for the discovered-gateways list, factored out of
//  the SwiftUI view so it can be unit-tested without an app/UI test target or a
//  live NWBrowser. The view (DiscoveredGatewayList) renders the state this
//  computes; the tests assert the state transitions.
//

import Foundation

public enum GatewayDiscoveryPresenter {

    /// Which UI state the discovered-gateways list should render.
    public enum ListState: Equatable {
        case scanning   // browsing, nothing found yet → progress indicator
        case empty      // not browsing and nothing found → "no gateways" hint
        case populated  // one or more gateways → the list
    }

    public static func listState(discoveredCount: Int, isBrowsing: Bool) -> ListState {
        if discoveredCount > 0 { return .populated }
        return isBrowsing ? .scanning : .empty
    }

    /// A discovered gateway is selectable (tappable to pair) only if it isn't
    /// already paired. `gatewayId` is compared against the set of paired ids.
    public static func isSelectable(gatewayId: String, pairedIds: Set<String>) -> Bool {
        !pairedIds.contains(gatewayId)
    }
}
