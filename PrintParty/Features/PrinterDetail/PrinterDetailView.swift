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

    /// Brief command feedback indicator.
    @State private var commandFeedback: CommandFeedback?

    private enum CommandFeedback: Equatable {
        case success(String)
        case error(String)
    }

    var body: some View {
        let state = registry.state(for: printer)
        let phase = registry.connectionPhase(for: printer)
        ScrollView {
            VStack(spacing: 20) {
                connectionBanner(phase: phase, state: state)
                JobProgressCard(state: state)
                temperatureCard(state: state)
                if printer.adapterKind == .gateway {
                    gatewayCommandsCard(state: state)
                }
                liveActivityCard(state: state)
                debugCard(state: state, phase: phase)
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

    @ViewBuilder
    private func connectionBanner(phase: ConnectionPhase, state: PrintJobState) -> some View {
        switch phase {
        case .connecting:
            connectingBanner
        case .connectedRelay:
            relayBanner
        case .push:
            pushFallbackBanner(state: state)
        case .disconnected(let reason):
            disconnectedBanner(reason: reason, state: state)
        case .connectedLAN:
            EmptyView()
        }
    }

    private var connectingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.adapterKind == .gateway
                     ? "Connecting to gateway\u{2026}"
                     : "Connecting to printer\u{2026}")
                    .font(.subheadline.weight(.medium))
                Text("Establishing connection. This usually takes a few seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var relayBanner: some View {
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

    private func disconnectedBanner(reason: String?, state: PrintJobState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Disconnected")
                    .font(.subheadline.weight(.medium))
                Text(reason ?? "Connection lost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let age = Date.now.timeIntervalSince(state.updatedAt)
                if age > 5 {
                    Text("Last data \(freshnessText(age: age))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
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

    private func debugCard(state: PrintJobState, phase: ConnectionPhase) -> some View {
        return DisclosureGroup("Debug \u{2014} Raw State") {
            VStack(alignment: .leading, spacing: 6) {
                debugRow("printerId", state.printerId.uuidString)
                debugRow("jobId", state.jobId?.uuidString ?? "\u{2014}")
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
                        .fill(phase.tint)
                        .frame(width: 8, height: 8)
                    Text("Phase: \(phase.displayName)")
                        .foregroundStyle(phase.tint)
                }
                .font(.caption.monospaced())

                if case .disconnected(let reason) = phase, let reason {
                    debugRow("reason", reason)
                }

                debugRow("data age", "\(Int(Date.now.timeIntervalSince(state.updatedAt)))s")
            }
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Gateway printer commands

    private func gatewayCommandsCard(state: PrintJobState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controls")
                .font(.headline)

            if let feedback = commandFeedback {
                HStack(spacing: 6) {
                    switch feedback {
                    case .success(let msg):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(msg)
                            .foregroundStyle(.secondary)
                    case .error(let msg):
                        Image(systemName: "exclamation.triangle.fill")
                            .foregroundStyle(.red)
                        Text(msg)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .transition(.opacity)
            }

            HStack(spacing: 12) {
                if state.stage == .printing {
                    Button {
                        Task { await sendCommand("pause") }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if state.stage == .paused {
                    Button {
                        Task { await sendCommand("resume") }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }

                if state.stage.isActive {
                    Button(role: .destructive) {
                        Task { await sendCommand("cancel") }
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !state.stage.isActive {
                Text("Commands available when a print is active.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.default, value: commandFeedback)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func sendCommand(_ command: String) async {
        guard let adapter = registry.adapter(for: activityPrinterId) as? GatewayAdapter else {
            commandFeedback = .error("No gateway connection")
            clearFeedbackAfterDelay()
            return
        }

        struct CommandPayload: Encodable {
            let printerId: UUID
            let command: String
        }

        do {
            _ = try await adapter.request("printer.command", payload: CommandPayload(
                printerId: activityPrinterId,
                command: command
            ))
            commandFeedback = .success("\(command.capitalized) sent")
        } catch {
            commandFeedback = .error(error.localizedDescription)
        }
        clearFeedbackAfterDelay()
    }

    private func clearFeedbackAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            commandFeedback = nil
        }
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
