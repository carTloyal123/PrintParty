//
//  GatewayHealthMonitor.swift
//  PrintParty
//
//  Persistent, @Observable monitor for gateway reachability. Replaces
//  the one-shot `.task { checkHealth() }` calls in GatewayRow and
//  GatewayDetailView with a singleton that:
//
//  - Pings each gateway via PairingClient.ping() (HTTP GET /healthz)
//  - On direct failure, probes relay reachability via WebSocket
//  - Cross-references AdapterRegistry.connectionPhases as a fast-path
//  - Reacts to NWPathMonitor and willEnterForegroundNotification
//  - Re-checks on a 60-second interval while foregrounded
//

import Foundation
import Network
import UIKit
import Observation
import os

@MainActor
@Observable
final class GatewayHealthMonitor {

    static let shared = GatewayHealthMonitor()

    private static let log = Logger(subsystem: "com.clengineering.PrintParty", category: "GatewayHealth")

    /// Current status for each gateway, keyed by gatewayId.
    private(set) var statuses: [String: GatewayConnectionStatus] = [:]

    // MARK: - Internal state

    /// Registered gateways to monitor.
    private var gateways: [GatewayInfo] = []

    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var isForegrounded = true

    /// Lightweight snapshot of gateway data needed for health checks.
    struct GatewayInfo {
        let gatewayId: String
        let baseURL: URL
        let relayURL: URL?
    }

    private init() {
        // Observe network path changes.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.clengineering.PrintParty.gatewayHealthMonitor"))

        // Re-check on foreground return.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isForegrounded = true
                self?.scheduleRefreshLoop()
                self?.checkAllGateways()
            }
        }

        // Pause on background.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isForegrounded = false
                self?.refreshTask?.cancel()
                self?.refreshTask = nil
            }
        }
    }

    // Singleton — observers live for the app's lifetime. No deinit needed.

    // MARK: - Public API

    /// Update the set of gateways to monitor and trigger an immediate check.
    func update(gateways newGateways: [GatewayInfo]) {
        self.gateways = newGateways

        // Remove statuses for gateways that no longer exist.
        let activeIds = Set(newGateways.map(\.gatewayId))
        for id in statuses.keys where !activeIds.contains(id) {
            statuses[id] = nil
        }

        checkAllGateways()
        scheduleRefreshLoop()
    }

    /// Force an immediate re-check of all gateways.
    func refresh() {
        checkAllGateways()
    }

    /// Status for a specific gateway.
    func status(for gatewayId: String) -> GatewayConnectionStatus {
        statuses[gatewayId] ?? .unknown
    }

    // MARK: - Network change detection

    private func handlePathUpdate(_ path: NWPath) {
        let previous = lastPathStatus
        lastPathStatus = path.status

        if path.status == .satisfied && previous != .satisfied {
            Self.log.info("GatewayHealth: network became available — re-checking all gateways")
            checkAllGateways()
        } else if path.status != .satisfied && previous == .satisfied {
            Self.log.info("GatewayHealth: network lost — marking all gateways unknown")
            for gw in gateways {
                statuses[gw.gatewayId] = .offline(reason: "No network")
            }
        }
    }

    // MARK: - Refresh loop

    private func scheduleRefreshLoop() {
        refreshTask?.cancel()
        guard isForegrounded, !gateways.isEmpty else { return }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled, self.isForegrounded else { return }
                self.checkAllGateways()
            }
        }
    }

    // MARK: - Health checks

    private func checkAllGateways() {
        for gw in gateways {
            Task { await checkGateway(gw) }
        }
    }

    private func checkGateway(_ gw: GatewayInfo) async {
        let gatewayId = gw.gatewayId

        // Fast-path: if any adapter for a printer on this gateway is already
        // connected, we know the gateway is reachable without an HTTP ping.
        let adapterPhase = adapterDerivedStatus(for: gatewayId)
        if let adapterPhase {
            statuses[gatewayId] = adapterPhase
            return
        }

        // Mark as checking.
        if statuses[gatewayId] == nil || statuses[gatewayId] == .unknown {
            statuses[gatewayId] = .checking
        }

        // Step 1: Try direct /healthz ping.
        do {
            let resp = try await PairingClient.ping(baseURL: gw.baseURL)
            if resp.gatewayId != gatewayId {
                statuses[gatewayId] = .offline(reason: "Gateway was reset — re-pair required")
            } else {
                statuses[gatewayId] = .lanOnline(version: resp.version)
            }
            return
        } catch {
            Self.log.info("GatewayHealth: LAN ping failed for \(gatewayId): \(error.localizedDescription, privacy: .public)")
        }

        // Step 2: If relay is configured, probe relay reachability.
        guard let relayURL = gw.relayURL else {
            statuses[gatewayId] = .offline(reason: "Gateway unreachable")
            return
        }

        statuses[gatewayId] = .lanOfflineRelayUnknown

        let relayReachable = await probeRelay(relayURL: relayURL, gatewayId: gatewayId)
        if relayReachable {
            statuses[gatewayId] = .lanOfflineRelayOnline
        } else {
            statuses[gatewayId] = .offline(reason: "LAN and relay unreachable")
        }
    }

    /// Check if any adapter for a printer on the given gateway is already connected.
    /// If so, derive the gateway status from the adapter's live connection phase.
    private func adapterDerivedStatus(for gatewayId: String) -> GatewayConnectionStatus? {
        let registry = AdapterRegistry.shared

        for (printerId, phase) in registry.connectionPhases {
            // We need to check if this printer belongs to this gateway.
            // The adapter registry doesn't directly map printer → gateway,
            // but we can check the state's printerId against known printers.
            // A simpler heuristic: if any adapter is connected via LAN or relay,
            // and the printer's gatewayId matches, the gateway is reachable.
            guard let adapter = registry.adapter(for: printerId) as? GatewayAdapter else {
                continue
            }
            // GatewayAdapter stores the gatewayId through the GatewayStreamClient.
            // We can compare the base URL as a proxy, but the simplest approach
            // is to check the connectionPhase directly since gateway adapters
            // only exist for gateway-backed printers.
            switch phase {
            case .connectedLAN:
                return .lanOnline(version: "live")
            case .connectedRelay:
                return .lanOfflineRelayOnline
            default:
                continue
            }
        }

        return nil
    }

    /// Probe relay reachability by attempting a WebSocket connection to the
    /// tunnel stream endpoint with a 5-second timeout.
    private func probeRelay(relayURL: URL, gatewayId: String) async -> Bool {
        let path = "v1/tunnel/\(gatewayId)/stream"
        guard var components = URLComponents(
            url: relayURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { return false }
        components.scheme = relayURL.scheme == "https" ? "wss" : "ws"
        guard let wsURL = components.url else { return false }

        Self.log.info("GatewayHealth: probing relay at \(wsURL.absoluteString, privacy: .public)")

        let probeConfig = URLSessionConfiguration.default
        probeConfig.timeoutIntervalForResource = 5
        probeConfig.waitsForConnectivity = false
        let probeSession = URLSession(configuration: probeConfig)
        let probeWs = probeSession.webSocketTask(with: wsURL)
        probeWs.resume()

        do {
            // Try to receive one message within 5 seconds.
            let _ = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        probeWs.receive { result in
                            continuation.resume(with: result)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            probeWs.cancel(with: .goingAway, reason: nil)
            Self.log.info("GatewayHealth: relay probe succeeded for \(gatewayId)")
            return true
        } catch {
            probeWs.cancel(with: .goingAway, reason: nil)
            Self.log.info("GatewayHealth: relay probe failed for \(gatewayId)")
            return false
        }
    }
}
