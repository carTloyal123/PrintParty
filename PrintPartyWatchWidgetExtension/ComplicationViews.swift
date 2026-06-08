//
//  ComplicationViews.swift
//  PrintPartyWatchWidgetExtension
//
//  Per-family rendering for the printer complication. Each watch-face family
//  gets a layout tuned to its size; all of them degrade gracefully to a
//  placeholder when no state has synced yet.
//

import WidgetKit
import SwiftUI
import PrintPartyKit

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PrinterComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCircular:   CircularComplication(entry: entry)
        case .accessoryCorner:     CornerComplication(entry: entry)
        case .accessoryInline:     InlineComplication(entry: entry)
        case .accessoryRectangular: RectangularComplication(entry: entry)
        default:                   CircularComplication(entry: entry)
        }
    }
}

// MARK: - Circular

private struct CircularComplication: View {
    let entry: PrinterComplicationEntry

    var body: some View {
        if let state = entry.state, state.stage.isActive {
            Gauge(value: state.progressPercent, in: 0...100) {
                Image(systemName: state.stage.symbolName)
            } currentValueLabel: {
                Text("\(Int(state.progressPercent))")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(state.stage.tint)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.state?.stage.symbolName ?? "printer")
                    .font(.title3)
            }
        }
    }
}

// MARK: - Corner

private struct CornerComplication: View {
    let entry: PrinterComplicationEntry

    var body: some View {
        let state = entry.state
        Image(systemName: state?.stage.symbolName ?? "printer")
            .font(.title2)
            .widgetLabel {
                if let state, state.stage.isActive {
                    Gauge(value: state.progressPercent, in: 0...100) {
                        Text(entry.printerName)
                    }
                    .tint(state.stage.tint)
                } else {
                    Text(state?.stage.displayName ?? entry.printerName)
                }
            }
    }
}

// MARK: - Inline

private struct InlineComplication: View {
    let entry: PrinterComplicationEntry

    var body: some View {
        if let state = entry.state {
            if state.stage.isActive {
                Label("\(entry.printerName) \(Int(state.progressPercent))%", systemImage: state.stage.symbolName)
            } else {
                Label("\(entry.printerName): \(state.stage.displayName)", systemImage: state.stage.symbolName)
            }
        } else {
            Label(entry.printerName, systemImage: "printer")
        }
    }
}

// MARK: - Rectangular

private struct RectangularComplication: View {
    let entry: PrinterComplicationEntry

    var body: some View {
        if let state = entry.state {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: state.stage.symbolName)
                        .foregroundStyle(state.stage.tint)
                    Text(entry.printerName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if state.stage.isActive {
                        Text("\(Int(state.progressPercent))%")
                            .font(.caption.monospacedDigit())
                    }
                }
                if state.stage.isActive {
                    ProgressView(value: state.progressPercent, total: 100)
                        .tint(state.stage.tint)
                    if let end = state.estimatedEndAt {
                        Text(timerInterval: Date.now...end, countsDown: true)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(state.substageMessage ?? state.stage.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading) {
                Label("PrintParty", systemImage: "printer")
                    .font(.headline)
                Text("Open the iPhone app to sync.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
