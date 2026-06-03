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
        }
        .modelContainer(sharedModelContainer)
    }
}
