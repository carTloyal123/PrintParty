//
//  PhoneSyncService.swift
//  PrintPartyWatch Watch App
//
//  Receives print-state snapshots from the iPhone over WatchConnectivity and is
//  the source of truth for the watch UI. Also persists each snapshot into the
//  shared App Group container and reloads complication timelines, so the watch
//  widget extension (which can't use WatchConnectivity) stays current.
//

import Foundation
import OSLog
import WatchConnectivity
import WidgetKit
import PrintPartyKit

@MainActor
@Observable
final class PhoneSyncService: NSObject {

    static let shared = PhoneSyncService()

    private let log = Logger(subsystem: "com.clengineering.PrintParty.watchkitapp", category: "PhoneSync")
    private let store = WatchSharedStore()

    /// Latest known state, observed by the watch views. Seeded from the App
    /// Group cache so the UI shows last-known data immediately on launch.
    private(set) var snapshot: WatchSnapshot

    /// Whether the phone is currently reachable (foreground, in range). Drives a
    /// subtle "live vs. last seen" affordance in the UI.
    private(set) var isPhoneReachable: Bool = false

    private override init() {
        snapshot = store?.load() ?? .empty
        super.init()
        activate()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Convenience lookup for the detail view.
    func state(for printerId: UUID) -> PrintJobState? {
        snapshot.printers.first { $0.printerId == printerId }
    }

    /// Apply a freshly-received snapshot: update the UI, cache it for the
    /// complication, and refresh complication timelines.
    fileprivate func apply(_ new: WatchSnapshot) {
        // Ignore out-of-order deliveries (applicationContext + message can race).
        guard new.generatedAt >= snapshot.generatedAt else { return }
        snapshot = new
        store?.save(new)
        WidgetCenter.shared.reloadAllTimelines()
    }

    fileprivate func decodeSnapshot(from payload: [String: Any]) -> WatchSnapshot? {
        guard let data = payload[WatchSyncKeys.snapshotMessageKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }
}

// MARK: - WCSessionDelegate

extension PhoneSyncService: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Capture the already-delivered context off the delegate queue, then
        // hop to the main actor to apply it. Without this, a cold launch shows
        // cached data until the phone happens to send the *next* update.
        let pending = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
            if let error {
                self.log.error("WCSession activation failed: \(error.localizedDescription)")
            }
            if let snapshot = self.decodeSnapshot(from: pending) {
                self.apply(snapshot)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.isPhoneReachable = session.isReachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            if let snapshot = self.decodeSnapshot(from: applicationContext) {
                self.apply(snapshot)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if let snapshot = self.decodeSnapshot(from: message) {
                self.apply(snapshot)
            }
        }
    }
}
