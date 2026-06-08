//
//  DeepLinkRouter.swift
//  PrintParty
//
//  Bridges `printparty://pair?...` deep links into the UI. PrintPartyApp writes
//  to this from `.onOpenURL`; AddGatewaySheet reads `pendingPairing` on appear
//  and pre-fills the pairing form.
//

import Foundation
import Observation
import PrintPartyKit

@MainActor
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    /// When set, the app should present / pre-fill a pairing sheet with these
    /// values. Cleared by the consumer once handled.
    var pendingPairing: PairingDeepLink.Payload?

    func handle(url: URL) {
        guard let payload = PairingDeepLink.parse(url) else { return }
        pendingPairing = payload
    }

    private init() {}
}
