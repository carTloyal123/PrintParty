//
//  WatchSyncService.swift
//  PrintParty
//
//  Relays the phone's authoritative print state to the paired Apple Watch over
//  WatchConnectivity. The phone owns every gateway connection; the watch is a
//  read-only mirror, so this is a one-way push (phone → watch).
//
//  Delivery strategy (matches Apple's "opportunistic" guidance):
//  • `updateApplicationContext` — always. Coalesces to the latest snapshot and
//    is delivered the next time the watch wakes, so the watch is correct on
//    wrist-raise even if it was asleep.
//  • `sendMessage` — additionally, when the watch is reachable, for low-latency
//    live updates while both apps are foregrounded.
//
//  WatchConnectivity exists only on iOS/watchOS. This app target also builds
//  for macOS and visionOS, so everything is gated behind `#if os(iOS)` with a
//  no-op stub elsewhere — callers (AdapterRegistry, the App) stay platform-clean.
//

import Foundation
import OSLog
import PrintPartyKit

#if os(iOS)

import WatchConnectivity

@MainActor
@Observable
final class WatchSyncService: NSObject {

    static let shared = WatchSyncService()

    private let log = Logger(subsystem: "com.clengineering.PrintParty", category: "WatchSync")

    /// The most recent snapshot we handed to WatchConnectivity. Surfaced for
    /// debugging / settings UI; not required for delivery.
    private(set) var lastSentSnapshot: WatchSnapshot?

    private var session: WCSession? {
        WCSession.isSupported() ? .default : nil
    }

    private override init() {
        super.init()
        activate()
    }

    /// Activates the WCSession. Safe to call once at app launch.
    func activate() {
        guard let session else {
            log.notice("WatchConnectivity not supported on this device")
            return
        }
        session.delegate = self
        session.activate()
    }

    /// Build a snapshot from the registry's current per-printer states and push
    /// it to the watch. Called from `AdapterRegistry` whenever state changes.
    func notify(states: [UUID: PrintJobState]) {
        // Deterministic ordering so the watch list doesn't reshuffle.
        let printers = states.values.sorted {
            if $0.printerDisplayName != $1.printerDisplayName {
                return $0.printerDisplayName.localizedCaseInsensitiveCompare($1.printerDisplayName) == .orderedAscending
            }
            return $0.printerId.uuidString < $1.printerId.uuidString
        }
        send(WatchSnapshot(printers: Array(printers)))
    }

    private func send(_ snapshot: WatchSnapshot) {
        guard let session, session.activationState == .activated else { return }
        guard let payload = try? JSONEncoder().encode(snapshot) else {
            log.error("Failed to encode WatchSnapshot")
            return
        }
        lastSentSnapshot = snapshot
        let message: [String: Any] = [WatchSyncKeys.snapshotMessageKey: payload]

        // Latest-state-wins, survives until the watch next wakes.
        do {
            try session.updateApplicationContext(message)
        } catch {
            log.error("updateApplicationContext failed: \(error.localizedDescription)")
        }

        // Best-effort live nudge when the watch is awake and reachable.
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { [weak self] error in
                Task { @MainActor in
                    self?.log.debug("sendMessage failed (non-fatal): \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSyncService: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            Task { @MainActor in self.log.error("WCSession activation failed: \(error.localizedDescription)") }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so a newly-paired watch keeps receiving updates.
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        // When the watch becomes reachable, push the latest snapshot right away
        // so it's current without waiting for the next state change.
        Task { @MainActor in
            if session.isReachable, let snapshot = self.lastSentSnapshot {
                self.send(snapshot)
            }
        }
    }
}

#else

// Platforms without WatchConnectivity (macOS, visionOS): no-op so callers
// remain platform-agnostic.
@MainActor
@Observable
final class WatchSyncService {
    static let shared = WatchSyncService()
    private init() {}
    func activate() {}
    func notify(states: [UUID: PrintJobState]) {}
}

#endif
