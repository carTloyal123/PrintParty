//
//  LiveActivityViews.swift
//  PrintPartyWidgetExtension
//
//  All SwiftUI views used by the Lock Screen banner and Dynamic Island
//  presentations of the PrintParty Live Activity.
//
//  Design notes:
//  • Use Text(timerInterval:) for elapsed/ETA wherever possible so the system
//    advances those values WITHOUT requiring a push update. This is critical
//    for staying under ActivityKit's push budget once we move to server pushes.
//  • Keep the layout compact and high-contrast — Lock Screen rendering is
//    glanceable, not interactive.
//

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Lock Screen / Banner

struct LockScreenLiveActivityView: View {
    let attributes: PrintPartyActivityAttributes
    let state: PrintJobState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ProgressView(value: state.progressPercent, total: 100)
                .tint(state.stage.tint)
            footer
        }
        .padding()
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: state.stage.symbolName)
                .font(.title2)
                .foregroundStyle(state.stage.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.jobName ?? attributes.printerDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(attributes.printerDisplayName) \u{2022} \(state.substageMessage ?? state.stage.displayName)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            Text("\(Int(state.progressPercent))%")
                .font(.title2.monospacedDigit().weight(.bold))
        }
    }

    private var footer: some View {
        HStack {
            if let current = state.currentLayer, let total = state.totalLayers, total > 0 {
                Label("\(current) / \(total)", systemImage: "square.stack.3d.up")
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            if let end = state.estimatedEndAt, state.stage.isActive {
                Label {
                    Text(timerInterval: Date.now...end, countsDown: true)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "clock")
                }
            } else if state.stage.isTerminal {
                Text(state.stage.displayName)
                    .foregroundStyle(state.stage.tint)
                    .fontWeight(.semibold)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: - Dynamic Island: Expanded

struct ExpandedLeadingView: View {
    let attributes: PrintPartyActivityAttributes
    let state: PrintJobState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(attributes.printerDisplayName, systemImage: "printer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(state.jobName ?? "—")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.leading, 4)
    }
}

struct ExpandedTrailingView: View {
    let state: PrintJobState

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Int(state.progressPercent))%")
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(state.stage.tint)
            Text(state.substageMessage ?? state.stage.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .padding(.trailing, 4)
    }
}

struct ExpandedBottomView: View {
    let state: PrintJobState

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: state.progressPercent, total: 100)
                .tint(state.stage.tint)
            HStack(spacing: 12) {
                if let current = state.currentLayer, let total = state.totalLayers, total > 0 {
                    Label("\(current)/\(total)", systemImage: "square.stack.3d.up")
                }
                Spacer()
                if let n = state.nozzleTempC {
                    Label("\(Int(n))°", systemImage: "thermometer.high")
                }
                if let b = state.bedTempC {
                    Label("\(Int(b))°", systemImage: "rectangle.fill")
                }
                Spacer()
                if let end = state.estimatedEndAt, state.stage.isActive {
                    Label {
                        Text(timerInterval: Date.now...end, countsDown: true)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Dynamic Island: Compact + Minimal

struct CompactLeadingView: View {
    let state: PrintJobState
    var body: some View {
        Image(systemName: state.stage.symbolName)
            .foregroundStyle(state.stage.tint)
    }
}

struct CompactTrailingView: View {
    let state: PrintJobState
    var body: some View {
        if state.stage.isActive {
            Text("\(Int(state.progressPercent))%")
                .monospacedDigit()
                .foregroundStyle(state.stage.tint)
        } else {
            Text(state.stage.displayName)
                .foregroundStyle(state.stage.tint)
        }
    }
}

struct MinimalView: View {
    let state: PrintJobState
    var body: some View {
        ZStack {
            // Ring showing progress.
            Circle()
                .stroke(state.stage.tint.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(state.progressPercent / 100))
                .stroke(state.stage.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: state.stage.symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(state.stage.tint)
        }
    }
}
