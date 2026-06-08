//
//  PrintPartyApp.swift
//  PrintParty
//

import SwiftUI
import SwiftData

@main
struct PrintPartyApp: App {

    /// Initializes the singleton on first access so the reconcile loop starts.
    private let liveActivityCoordinator = LiveActivityCoordinator.shared

    /// Initializes the registry on first access so it's ready before any view
    /// tries to read state from it.
    private let adapterRegistry = AdapterRegistry.shared

    /// Initializes the gateway health monitor so it starts tracking immediately.
    private let gatewayHealthMonitor = GatewayHealthMonitor.shared

    /// Activates WatchConnectivity on first access so the paired Apple Watch
    /// starts receiving state snapshots as soon as the app launches.
    private let watchSyncService = WatchSyncService.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Printer.self,
            Gateway.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            PrintersListView()
                .onOpenURL { url in
                    DeepLinkRouter.shared.handle(url: url)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
