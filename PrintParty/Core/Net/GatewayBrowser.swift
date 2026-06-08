//
//  GatewayBrowser.swift
//  PrintParty
//
//  Discovers PrintParty gateways on the LAN via Bonjour/mDNS so the user
//  doesn't have to type a URL. Browses for `_printparty._tcp` services using
//  the Network framework's NWBrowser, reads the TXT record (gid/name/ver/port),
//  and resolves each service to a concrete IP address.
//
//  The gateway advertises its real HTTP port inside the TXT `port` field (its
//  NWListener runs on an ephemeral port — see BonjourAdvertiser), so we prefer
//  the TXT port and fall back to the resolved endpoint's port.
//
//  Requires NSBonjourServices + NSLocalNetworkUsageDescription in Info.plist
//  and triggers the iOS Local Network permission prompt on first browse.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class GatewayBrowser {

    struct DiscoveredGateway: Identifiable, Equatable {
        let id: String          // gatewayId prefix from TXT record (gid field)
        let name: String        // from TXT record (name field)
        let host: String        // resolved IP address
        let port: UInt16        // real HTTP port (TXT `port`, else service port)
        let version: String     // from TXT record (ver field)

        var baseURL: URL? {
            URL(string: "http://\(host):\(port)")
        }
    }

    private(set) var discoveredGateways: [DiscoveredGateway] = []
    private(set) var isBrowsing = false

    private var browser: NWBrowser?
    /// In-flight IP resolutions keyed by the service endpoint, so we don't
    /// start duplicate connections and can cancel them on stop.
    private var pendingResolutions: [NWEndpoint: NWConnection] = [:]

    func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_printparty._tcp", domain: nil),
            using: params
        )
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleResultsChanged(results, changes: changes)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed = state {
                    self?.isBrowsing = false
                }
            }
        }
        browser.start(queue: .main)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        for (_, conn) in pendingResolutions { conn.cancel() }
        pendingResolutions.removeAll()
    }

    // MARK: - Result handling

    private func handleResultsChanged(
        _ results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>
    ) {
        for change in changes {
            switch change {
            case .added(let result):
                resolve(result)
            case .removed(let result):
                remove(result)
            case .changed(old: _, new: let result, flags: _):
                resolve(result)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    /// Parse the TXT record and kick off IP resolution for a discovered result.
    private func resolve(_ result: NWBrowser.Result) {
        guard case let .bonjour(txtRecord) = result.metadata else { return }

        let gid = txtRecord["gid"] ?? fallbackId(for: result.endpoint)
        let name = txtRecord["name"] ?? gid
        let version = txtRecord["ver"] ?? ""
        let txtPort = txtRecord["port"].flatMap { UInt16($0) }

        // Don't start a second resolution for an endpoint we're already resolving.
        guard pendingResolutions[result.endpoint] == nil else { return }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        pendingResolutions[result.endpoint] = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    if let (host, resolvedPort) = Self.hostAndPort(from: connection) {
                        let gateway = DiscoveredGateway(
                            id: gid,
                            name: name,
                            host: host,
                            port: txtPort ?? resolvedPort,
                            version: version
                        )
                        self.upsert(gateway)
                    }
                    self.finishResolution(for: result.endpoint)
                case .failed, .cancelled:
                    self.finishResolution(for: result.endpoint)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func finishResolution(for endpoint: NWEndpoint) {
        if let conn = pendingResolutions.removeValue(forKey: endpoint) {
            conn.cancel()
        }
    }

    /// Insert or replace a gateway, de-duplicating by gatewayId (gid).
    private func upsert(_ gateway: DiscoveredGateway) {
        if let idx = discoveredGateways.firstIndex(where: { $0.id == gateway.id }) {
            discoveredGateways[idx] = gateway
        } else {
            discoveredGateways.append(gateway)
        }
    }

    private func remove(_ result: NWBrowser.Result) {
        finishResolution(for: result.endpoint)
        guard case let .bonjour(txtRecord) = result.metadata else { return }
        let gid = txtRecord["gid"] ?? fallbackId(for: result.endpoint)
        discoveredGateways.removeAll { $0.id == gid }
    }

    /// Stable identifier when the TXT record has no gid (shouldn't happen with
    /// our gateway, but keeps discovery functional for malformed advertisers).
    private func fallbackId(for endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return String(describing: endpoint)
    }

    /// Extract the resolved host IP and port from a ready connection.
    private static func hostAndPort(from connection: NWConnection) -> (String, UInt16)? {
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case let .hostPort(host, port) = endpoint else { return nil }

        let hostString: String
        switch host {
        case .ipv4(let addr):
            hostString = "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
        case .ipv6(let addr):
            hostString = "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
        case .name(let name, _):
            hostString = name
        @unknown default:
            return nil
        }
        return (hostString, port.rawValue)
    }
}
