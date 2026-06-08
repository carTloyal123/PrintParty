//
//  PrintPartyWatchWidgetExtension.swift
//  PrintPartyWatchWidgetExtension
//
//  Watch-face complication showing a chosen printer's status. The timeline is
//  fed from the shared App Group snapshot the watch app maintains; the watch app
//  calls WidgetCenter.reloadAllTimelines() on every sync, so entries stay fresh
//  without the widget needing its own connection.
//

import WidgetKit
import SwiftUI
import PrintPartyKit

struct PrinterComplicationEntry: TimelineEntry {
    let date: Date
    let state: PrintJobState?
    /// Fallback name when no state is cached yet (e.g. right after configuration).
    let printerName: String
}

struct PrinterComplicationProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> PrinterComplicationEntry {
        PrinterComplicationEntry(date: Date(), state: nil, printerName: "Printer")
    }

    func snapshot(for configuration: SelectPrinterIntent, in context: Context) async -> PrinterComplicationEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectPrinterIntent, in context: Context) async -> Timeline<PrinterComplicationEntry> {
        let entry = entry(for: configuration)
        // Push-driven (watch app reloads on each sync); refresh occasionally as
        // a safety net in case a reload is missed.
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    func recommendations() -> [AppIntentRecommendation<SelectPrinterIntent>] {
        let snapshot = WatchSharedStore()?.load() ?? .empty
        return snapshot.printers.map { state in
            let intent = SelectPrinterIntent()
            intent.printer = PrinterEntity(id: state.printerId.uuidString, name: state.printerDisplayName)
            return AppIntentRecommendation(intent: intent, description: state.printerDisplayName)
        }
    }

    private func entry(for configuration: SelectPrinterIntent) -> PrinterComplicationEntry {
        let snapshot = WatchSharedStore()?.load() ?? .empty
        let selectedId = configuration.printer?.id
        // Fall back to the first known printer if none is configured yet.
        let state = snapshot.printers.first { $0.printerId.uuidString == selectedId }
            ?? snapshot.printers.first
        let name = state?.printerDisplayName ?? configuration.printer?.name ?? "Printer"
        return PrinterComplicationEntry(date: Date(), state: state, printerName: name)
    }
}

struct PrinterComplication: Widget {
    let kind: String = "PrinterComplication"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectPrinterIntent.self,
            provider: PrinterComplicationProvider()
        ) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Printer Status")
        .description("Track a printer's progress at a glance.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryInline,
            .accessoryRectangular,
            .accessoryCorner,
        ])
    }
}
