//
//  AppIntent.swift
//  PrintPartyWatchWidgetExtension
//
//  Widget configuration for the printer complication: lets the user pick which
//  printer a complication tracks. The list of printers comes from the snapshot
//  the watch app writes into the shared App Group container.
//

import WidgetKit
import AppIntents
import PrintPartyKit

/// A printer the user can attach a complication to.
struct PrinterEntity: AppEntity {
    let id: String          // PrintJobState.printerId.uuidString
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Printer" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var defaultQuery = PrinterEntityQuery()
}

struct PrinterEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PrinterEntity] {
        allPrinters().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PrinterEntity] {
        allPrinters()
    }

    func defaultResult() -> PrinterEntity? {
        allPrinters().first
    }

    private func allPrinters() -> [PrinterEntity] {
        let snapshot = WatchSharedStore()?.load() ?? .empty
        return snapshot.printers.map {
            PrinterEntity(id: $0.printerId.uuidString, name: $0.printerDisplayName)
        }
    }
}

struct SelectPrinterIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Select Printer" }
    static var description: IntentDescription { "Choose which printer this complication tracks." }

    @Parameter(title: "Printer")
    var printer: PrinterEntity?
}
