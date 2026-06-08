//
//  WatchSharedStore.swift
//  PrintPartyKit
//
//  Persists the latest `WatchSnapshot` into the App Group container shared
//  between the watch app (writer) and the watch widget extension / complication
//  (reader). This is the only handoff between those two processes — the widget
//  cannot talk to WatchConnectivity, so it reads whatever the app last wrote.
//
//  Apple-platforms only: the App Group container is a UserDefaults suite. The
//  iOS app does not need this (it talks to the watch directly over WCSession),
//  but the type is available there too for symmetry.
//

#if os(iOS) || os(watchOS)

import Foundation

public struct WatchSharedStore: Sendable {

    private let defaults: UserDefaults

    /// Creates a store backed by the shared App Group suite. Returns `nil` if
    /// the App Group is misconfigured (entitlement missing / wrong id), which
    /// surfaces the setup mistake instead of silently no-op'ing.
    public init?(appGroupID: String = WatchSyncKeys.appGroupID) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return nil }
        self.defaults = defaults
    }

    /// Writes the snapshot as JSON. Call `WidgetCenter.reloadAllTimelines()`
    /// from the app target afterwards — this type stays WidgetKit-free so it
    /// can live in the cross-platform package.
    public func save(_ snapshot: WatchSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: WatchSyncKeys.snapshotDefaultsKey)
    }

    /// Reads the last-saved snapshot, or `.empty` if nothing has synced yet.
    public func load() -> WatchSnapshot {
        guard
            let data = defaults.data(forKey: WatchSyncKeys.snapshotDefaultsKey),
            let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data)
        else {
            return .empty
        }
        return snapshot
    }
}

#endif
