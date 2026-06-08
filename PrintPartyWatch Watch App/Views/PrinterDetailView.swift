//
//  PrinterDetailView.swift
//  PrintPartyWatch Watch App
//
//  Per-printer detail: large progress ring, stage, layer count, temperatures,
//  and a locally-ticking ETA. Reads live state from PhoneSyncService so it
//  updates in place as new snapshots arrive from the phone.
//

import SwiftUI
import PrintPartyKit

struct PrinterDetailView: View {
    let printerId: UUID
    @State private var sync = PhoneSyncService.shared

    private var state: PrintJobState? { sync.state(for: printerId) }

    var body: some View {
        ScrollView {
            if let state {
                VStack(spacing: 14) {
                    ProgressRingView(state: state)
                        .frame(width: 110, height: 110)
                        .padding(.top, 4)

                    Text(state.substageMessage ?? state.stage.displayName)
                        .font(.headline)
                        .foregroundStyle(state.stage.tint)
                        .multilineTextAlignment(.center)

                    if let jobName = state.jobName {
                        Text(jobName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }

                    etaRow(state)
                    metrics(state)
                }
                .padding(.horizontal, 4)
                .navigationTitle(state.printerDisplayName)
            } else {
                ContentUnavailableView("Printer Unavailable", systemImage: "wifi.slash")
            }
        }
    }

    @ViewBuilder
    private func etaRow(_ state: PrintJobState) -> some View {
        if let end = state.estimatedEndAt, state.stage.isActive {
            Label {
                Text(timerInterval: Date.now...end, countsDown: true)
                    .font(.body.monospacedDigit())
            } icon: {
                Image(systemName: "clock")
            }
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func metrics(_ state: PrintJobState) -> some View {
        VStack(spacing: 8) {
            if let current = state.currentLayer, let total = state.totalLayers, total > 0 {
                metricRow(symbol: "square.stack.3d.up", label: "Layer", value: "\(current) / \(total)")
            }
            if let nozzle = state.nozzleTempC {
                metricRow(
                    symbol: "thermometer.high",
                    label: "Nozzle",
                    value: tempString(nozzle, target: state.nozzleTargetC)
                )
            }
            if let bed = state.bedTempC {
                metricRow(
                    symbol: "rectangle.fill",
                    label: "Bed",
                    value: tempString(bed, target: state.bedTargetC)
                )
            }
            if let message = state.errorMessage, state.stage == .failed {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func metricRow(symbol: String, label: String, value: String) -> some View {
        HStack {
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tempString(_ current: Double, target: Double?) -> String {
        if let target, target > 0 {
            return "\(Int(current))° → \(Int(target))°"
        }
        return "\(Int(current))°"
    }
}
