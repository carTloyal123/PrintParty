//
//  DiscoveredGatewayList.swift
//  PrintParty
//
//  Renders the gateways found on the LAN by GatewayBrowser. Designed to be
//  embedded as a Section inside AddGatewaySheet. Already-paired gateways are
//  shown with a checkmark and are non-tappable.
//

import SwiftUI
import UIKit
import PrintPartyKit

struct DiscoveredGatewayList: View {
    let gateways: [GatewayBrowser.DiscoveredGateway]
    let pairedGatewayIds: Set<String>
    let onSelect: (GatewayBrowser.DiscoveredGateway) -> Void
    let isBrowsing: Bool

    var body: some View {
        switch GatewayDiscoveryPresenter.listState(discoveredCount: gateways.count, isBrowsing: isBrowsing) {
        case .scanning:
            HStack(spacing: 10) {
                ProgressView()
                Text("Scanning local network\u{2026}")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning local network for gateways")
        case .empty:
            Label("No gateways found on this network.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
                .font(.callout)
        case .populated:
            ForEach(gateways) { gw in
                let isPaired = !GatewayDiscoveryPresenter.isSelectable(gatewayId: gw.id, pairedIds: pairedGatewayIds)
                Button {
                    if !isPaired {
                        UISelectionFeedbackGenerator().selectionChanged()
                        onSelect(gw)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gw.name).font(.body)
                            Text(gw.host).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isPaired {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "arrow.right.circle").foregroundStyle(.blue)
                        }
                    }
                }
                .disabled(isPaired)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Gateway \(gw.name) at \(gw.host)")
                .accessibilityHint(isPaired ? "Already paired" : "Tap to fill in this gateway's address")
            }
        }
    }
}
