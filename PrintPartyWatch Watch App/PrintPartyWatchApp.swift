//
//  PrintPartyWatchApp.swift
//  PrintPartyWatch Watch App
//

import SwiftUI

@main
struct PrintPartyWatch_Watch_AppApp: App {

    /// Activate WatchConnectivity on first access so snapshots from the iPhone
    /// start flowing (and seed the UI from the cached snapshot) at launch.
    @State private var sync = PhoneSyncService.shared

    var body: some Scene {
        WindowGroup {
            PrinterListView()
        }

        // Custom long-look UI for forwarded print events.
        WKNotificationScene(controller: PrintNotificationController.self, category: "PRINT_EVENT")
    }
}
