//
//  PrinterDetailView.swift
//  PrintParty
//

import SwiftUI

struct PrinterDetailView: View {

    let printer: Printer

    private var registry: AdapterRegistry { .shared }
    private var coordinator: LiveActivityCoordinator { .shared }

    /// The printerId the LiveActivityCoordinator tracks for this printer.
    /// For gateway printers this is the remotePrinterId; for others it's
    /// the local Printer.id.
    private var activityPrinterId: UUID {
        printer.remotePrinterId ?? printer.id
    }

    @State private var liveActivityEnabled = true
    @AppStorage(LiveActivityCoordinator.lingerEnabledKey)
    private var lingerEnabled: Bool = true
    @AppStorage(LiveActivityCoordinator.lingerDurationKey)
    private var lingerDuration: Double = LiveActivityCoordinator.defaultLingerDuration

    var body: some View {
        let state = registry.state(for: printer)
        let source = registry.stateSource(for: printer)
        ScrollView {
            VStack(spacing: 20) {
                if source == .push {
                    pushFallbackBanner(state: state)
                } else if source == .relay {
                    relayBanner(state: state)
                }
                JobProgressCard(state: state)
                temperatureCard(state: state)
                liveActivityCard(state: state)
                controlsCard(state: state)
                debugCard(state: state)
            }
            .padding()
        }
        .navigationTitle(printer.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            liveActivityEnabled = coordinator.liveActivityEnabled(for: activityPrinterId)
        }
    }

    // MARK: Cards

    private func relayBanner(state: PrintJobState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connected via relay")
                    .font(.subheadline.weight(.medium))
                Text("Remote access through relay tunnel. Data may be slightly delayed compared to LAN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pushFallbackBanner(state: PrintJobState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Updated via push")
                    .font(.subheadline.weight(.medium))
                Text("Not connected to gateway. Showing data from Live Activity push updates. Last update \(state.updatedAt.formatted(date: .omitted, time: .standard)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func liveActivityCard(state: PrintJobState) -> some View {
        let isRunning = coordinator.hasRunningActivity(for: activityPrinterId)

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Live Activity")
                    .font(.headline)
                Spacer()
                if isRunning {
                    Text("Active")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }

            // Primary toggle: enable/disable Live Activity for this printer
            Toggle(isOn: $liveActivityEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enabled")
                    Text(enabledStatusText(state: state, isRunning: isRunning))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: liveActivityEnabled) { _, newValue in
                Task {
                    await coordinator.setLiveActivityEnabled(newValue, for: activityPrinterId)
                }
            }

            // Nested settings: only shown when Live Activity is enabled
            if liveActivityEnabled {
                Divider()

                Toggle(isOn: $lingerEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-dismiss after print")
                        Text(lingerEnabled
                            ? "Activity will dismiss \(lingerLabel) after the print finishes."
                            : "Activity stays until you turn it off manually.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if lingerEnabled {
                    Picker("Dismiss after", selection: $lingerDuration) {
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                        Text("15 minutes").tag(900.0)
                        Text("30 minutes").tag(1800.0)
                        Text("1 hour").tag(3600.0)
                        Text("4 hours").tag(14400.0)
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .animation(.default, value: liveActivityEnabled)
        .animation(.default, value: lingerEnabled)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var lingerLabel: String {
        switch lingerDuration {
        case 30:    return "30 seconds"
        case 60:    return "1 minute"
        case 300:   return "5 minutes"
        case 900:   return "15 minutes"
        case 1800:  return "30 minutes"
        case 3600:  return "1 hour"
        case 14400: return "4 hours"
        default:    return "\(Int(lingerDuration))s"
        }
    }

    private func enabledStatusText(state: PrintJobState, isRunning: Bool) -> String {
        if !liveActivityEnabled {
            return "Enable to show this printer on your Lock Screen."
        }
        if isRunning && state.stage.isActive {
            return "Showing live progress on Lock Screen."
        }
        if isRunning {
            return "Showing on Lock Screen."
        }
        return "Will appear when a print starts."
    }

    private func temperatureCard(state: PrintJobState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temperatures")
                .font(.headline)
            HStack(spacing: 24) {
                tempReadout(
                    label: "Nozzle",
                    symbol: "thermometer.high",
                    current: state.nozzleTempC,
                    target: state.nozzleTargetC,
                    tint: .orange
                )
                tempReadout(
                    label: "Bed",
                    symbol: "rectangle.fill",
                    current: state.bedTempC,
                    target: state.bedTargetC,
                    tint: .red
                )
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func tempReadout(
        label: String,
        symbol: String,
        current: Double?,
        target: Double?,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(current.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                Text("°C")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let target {
                Text("Target \(Int(target))°C")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlsCard(state: PrintJobState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controls")
                .font(.headline)
            controlButtons(state: state)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func controlButtons(state: PrintJobState) -> some View {
        let source = registry.stateSource(for: printer)
        if source == .push {
            Label("Controls unavailable — not connected to gateway.", systemImage: "wifi.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            switch printer.adapterKind {
            case .bambuLabA1Mini:
                bambuControls(state: state)
            case .gateway:
                gatewayControls(state: state)
            }
        }
    }

    @ViewBuilder
    private func bambuControls(state: PrintJobState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Bambu LAN adapter is a stub", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("The MQTT client lands in the next update. The printer's host, serial, and access code are already stored — the adapter just needs to connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let host = printer.host {
                Text("Host: \(host)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            if let serial = printer.serial {
                Text("Serial: \(serial)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func gatewayControls(state: PrintJobState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Managed by gateway", systemImage: "server.rack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("This printer is connected through your self-hosted gateway. Telemetry streams via WebSocket; commands will be added in a future update.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let gid = printer.gatewayId {
                Text("Gateway: \(gid)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func debugCard(state: PrintJobState) -> some View {
        let source = registry.stateSource(for: printer)
        return DisclosureGroup("Debug — Raw State") {
            VStack(alignment: .leading, spacing: 6) {
                debugRow("printerId", state.printerId.uuidString)
                debugRow("jobId", state.jobId?.uuidString ?? "—")
                debugRow("stage", state.stage.rawValue)
                debugRow("progress", String(format: "%.2f%%", state.progressPercent))
                debugRow("layer", "\(state.currentLayer ?? 0) / \(state.totalLayers ?? 0)")
                debugRow("updated", state.updatedAt.formatted(date: .omitted, time: .standard))
                if let code = state.errorCode {
                    debugRow("error", code)
                }

                Divider()

                HStack(spacing: 6) {
                    Circle()
                        .fill(source == .push ? Color.orange : (source == .relay ? Color.blue : Color.green))
                        .frame(width: 8, height: 8)
                    Text("Source: \(source == .push ? "Push (APNs)" : (source == .relay ? "Relay (WebSocket)" : "Adapter (WebSocket)"))")
                        .foregroundStyle(source == .push ? .orange : (source == .relay ? .blue : .green))
                }
                .font(.caption.monospaced())

                if source == .push {
                    debugRow("push age", "\(Int(Date.now.timeIntervalSince(state.updatedAt)))s ago")
                }
            }
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
