//
//  SmartStackLiveActivityView.swift
//  PrintPartyWidgetExtension
//
//  The Live Activity content for the lock screen (.medium, iOS) and the Apple
//  Watch Smart Stack (.small, watchOS). On watchOS 11+, an iOS Live Activity
//  automatically appears in the Smart Stack; declaring the `.small` supplemental
//  activity family (see PrintPartyLiveActivity) lets us render a wrist-sized
//  layout instead of one derived from the Dynamic Island.
//

import ActivityKit
import SwiftUI
import WidgetKit
import PrintPartyKit

/// Chooses the right layout for the current presentation context.
struct LiveActivityContentView: View {
    @Environment(\.activityFamily) private var activityFamily

    let attributes: PrintPartyActivityAttributes
    let state: PrintJobState

    var body: some View {
        switch activityFamily {
        case .small:
            SmartStackLiveActivityView(attributes: attributes, state: state)
        case .medium:
            LockScreenLiveActivityView(attributes: attributes, state: state)
        @unknown default:
            LockScreenLiveActivityView(attributes: attributes, state: state)
        }
    }
}

/// Compact card tuned for the Apple Watch Smart Stack: a leading progress ring,
/// printer + stage, and a locally-ticking ETA. No interaction — pure glance.
struct SmartStackLiveActivityView: View {
    let attributes: PrintPartyActivityAttributes
    let state: PrintJobState

    var body: some View {
        HStack(spacing: 10) {
            progressRing
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.printerDisplayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(state.substageMessage ?? state.stage.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                trailingDetail
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(state.stage.tint.opacity(0.25), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(state.progressPercent / 100))
                .stroke(state.stage.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if state.stage.isActive {
                Text("\(Int(state.progressPercent))")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
            } else {
                Image(systemName: state.stage.symbolName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(state.stage.tint)
            }
        }
    }

    @ViewBuilder
    private var trailingDetail: some View {
        if let end = state.estimatedEndAt, state.stage.isActive {
            Label {
                Text(timerInterval: Date.now...end, countsDown: true)
            } icon: {
                Image(systemName: "clock")
            }
        } else if let current = state.currentLayer, let total = state.totalLayers, total > 0 {
            Label("\(current)/\(total)", systemImage: "square.stack.3d.up")
        }
    }
}
