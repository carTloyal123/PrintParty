//
//  PrinterRowView.swift
//  PrintParty
//

import SwiftUI

struct PrinterRowView: View {

    let printer: Printer

    private var registry: AdapterRegistry { .shared }

    /// Pulsing animation state for the "connecting" dot.
    @State private var isPulsing = false

    var body: some View {
        let state = registry.state(for: printer)
        let phase = registry.connectionPhase(for: printer)
        HStack(spacing: 14) {
            // Connection status dot + stage icon stack
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: state.stage.symbolName)
                    .font(.title2)
                    .foregroundStyle(state.stage.tint)
                    .frame(width: 32)
                // Small dot indicating connection path
                connectionDot(phase: phase)
            }
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(printer.displayName)
                    .font(.headline)
                HStack(spacing: 6) {
                    connectionLabel(phase: phase)
                    if phase == .push || phase == .disconnected() {
                        freshnessLabel(state: state)
                    }
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

    /// Small colored dot showing the connection phase.
    @ViewBuilder
    private func connectionDot(phase: ConnectionPhase) -> some View {
        Circle()
            .fill(phase.tint)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color(.systemBackground), lineWidth: 1.5)
            )
            .opacity(phase.isConnecting ? (isPulsing ? 0.3 : 1.0) : 1.0)
            .animation(
                phase.isConnecting
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear { isPulsing = true }
            .onChange(of: phase) { _, newPhase in
                // Reset pulsing when phase changes away from connecting
                isPulsing = newPhase.isConnecting
            }
    }

    /// Label showing how the printer is connected.
    @ViewBuilder
    private func connectionLabel(phase: ConnectionPhase) -> some View {
        switch phase {
        case .connecting:
            Label("Connecting\u{2026}", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .connectedRelay:
            Label("Remote", systemImage: "globe")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .push:
            Label("Push", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .disconnected:
            Label("Offline", systemImage: "wifi.slash")
                .font(.caption2)
                .foregroundStyle(.red)
        case .connectedLAN:
            Label("Gateway", systemImage: "server.rack")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Relative timestamp showing data freshness for push/disconnected states.
    @ViewBuilder
    private func freshnessLabel(state: PrintJobState) -> some View {
        let age = Date.now.timeIntervalSince(state.updatedAt)
        if age > 5 { // Only show if data is more than 5 seconds old
            Text("\u{2022}")
                .foregroundStyle(.secondary)
            Text(freshnessText(age: age))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func freshnessText(age: TimeInterval) -> String {
        if age < 60 {
            return "\(Int(age))s ago"
        } else if age < 3600 {
            return "\(Int(age / 60))m ago"
        } else {
            return "\(Int(age / 3600))h ago"
        }
    }
}
