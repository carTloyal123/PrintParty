//
//  WatchSnapshot.swift
//  PrintPartyKit
//
//  The consolidated state the iPhone relays to the Apple Watch over
//  WatchConnectivity, and that the watch app persists into the shared App
//  Group container so the complication widget extension can read it.
//
//  This is deliberately a thin wrapper around the existing `PrintJobState`
//  array — the watch shows exactly what the phone knows, no more. Keep it
//  Foundation-only (Codable) so it compiles on every PrintPartyKit platform,
//  including the Linux gateway.
//

import Foundation

public struct WatchSnapshot: Codable, Sendable, Equatable {

    /// Latest known state for every printer the phone is tracking, in the
    /// order the phone wants them displayed.
    public var printers: [PrintJobState]

    /// When the phone produced this snapshot. The watch uses this to decide
    /// whether the data is fresh enough to present as "live" vs. "last seen".
    public var generatedAt: Date

    public init(printers: [PrintJobState], generatedAt: Date = .now) {
        self.printers = printers
        self.generatedAt = generatedAt
    }

    /// An empty snapshot — used as the placeholder before the first sync.
    public static let empty = WatchSnapshot(printers: [], generatedAt: .distantPast)
}

/// Shared identifiers used by both sides of the phone⇄watch link and by the
/// watch app⇄complication App Group handoff. Keep these in one place so the
/// iOS app, watch app, and watch widget extension never drift apart.
public enum WatchSyncKeys {

    /// App Group shared between the watch app and its widget extension.
    /// Must match the `com.apple.security.application-groups` entitlement on
    /// both watch targets.
    public static let appGroupID = "group.com.carsonloyal.printparty.watch"

    /// UserDefaults key under which the encoded `WatchSnapshot` is stored in
    /// the App Group container.
    public static let snapshotDefaultsKey = "watch.snapshot.v1"

    /// Key for the encoded `WatchSnapshot` inside a WatchConnectivity
    /// application-context dictionary or message.
    public static let snapshotMessageKey = "snapshot"
}
