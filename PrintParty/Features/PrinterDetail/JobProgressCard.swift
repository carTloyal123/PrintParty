//
//  JobProgressCard.swift
//  PrintParty
//

import SwiftUI

struct JobProgressCard: View {

    let state: PrintJobState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            progressBar
            metadataGrid
            if let message = state.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: state.stage.symbolName)
                .font(.title)
                .foregroundStyle(state.stage.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.substageMessage ?? state.stage.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(state.stage.tint)
                    .lineLimit(1)
                Text(state.jobName ?? "No active job")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if state.stage.isActive {
                Text("\(Int(state.progressPercent))%")
                    .font(.title.monospacedDigit().weight(.bold))
            }
        }
    }

    private var progressBar: some View {
        ProgressView(value: state.progressPercent, total: 100)
            .progressViewStyle(.linear)
            .tint(state.stage.tint)
            .opacity(state.stage == .idle ? 0.3 : 1)
    }

    private var metadataGrid: some View {
        HStack(spacing: 24) {
            metadataItem(
                title: "Layer",
                value: layerString
            )
            metadataItem(
                title: "ETA",
                value: etaString
            )
            metadataItem(
                title: "Elapsed",
                value: elapsedString
            )
        }
    }

    private func metadataItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var layerString: String {
        guard let current = state.currentLayer, let total = state.totalLayers, total > 0 else {
            return "—"
        }
        return "\(current) / \(total)"
    }

    private var etaString: String {
        guard let end = state.estimatedEndAt, state.stage.isActive else { return "—" }
        let remaining = end.timeIntervalSinceNow
        if remaining <= 0 { return "soon" }
        return Self.componentsFormatter.string(from: remaining) ?? "—"
    }

    private var elapsedString: String {
        guard let start = state.startedAt else { return "—" }
        return Self.componentsFormatter.string(from: Date.now.timeIntervalSince(start)) ?? "—"
    }

    private static let componentsFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropLeading
        return f
    }()
}
