//
//  PrinterRowView.swift
//  PrintParty
//

import SwiftUI

struct PrinterRowView: View {

    let printer: Printer

    private var registry: AdapterRegistry { .shared }

    var body: some View {
        let state = registry.state(for: printer)
        HStack(spacing: 14) {
            // Connection status dot + stage icon stack
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: state.stage.symbolName)
                    .font(.title2)
                    .foregroundStyle(state.stage.tint)
                    .frame(width: 32)
                // Small dot indicating connection path
                connectionDot
            }
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(printer.displayName)
                    .font(.headline)
                HStack(spacing: 6) {
                    connectionLabel
                    Text("\u{2022}")
                        .foregroundStyle(.secondary)
                    Text(state.substageMessage ?? state.stage.displayName)
                        .font(.subheadline)
                        .foregroundStyle(state.stage.tint)
                        .lineLimit(1)
                }
            }
            Spacer()
            if state.stage.isActive {
                Text("\(Int(state.progressPercent))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Connection indicators

    /// Small colored dot showing the connection path health.
    @ViewBuilder
    private var connectionDot: some View {
        let state = registry.state(for: printer)
        let source = registry.stateSource(for: printer)
        Circle()
            .fill(dotColor(source: source, stage: state.stage))
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color(.systemBackground), lineWidth: 1.5)
            )
    }

    private func dotColor(source: AdapterRegistry.StateSource, stage: PrinterStage) -> Color {
        switch source {
        case .push:    return .orange
        case .relay:   return .blue
        case .adapter: return stage == .offline ? .red : .green
        }
    }

    /// Label showing how the printer is connected.
    @ViewBuilder
    private var connectionLabel: some View {
        let source = registry.stateSource(for: printer)
        switch source {
        case .push:
            Label("Push", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .relay:
            Label("Remote", systemImage: "globe")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .adapter:
            switch printer.adapterKind {
            case .bambuLabA1Mini:
                Label("LAN", systemImage: "wifi")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .gateway:
                Label("Gateway", systemImage: "server.rack")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
