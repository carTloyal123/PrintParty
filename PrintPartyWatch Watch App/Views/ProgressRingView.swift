//
//  ProgressRingView.swift
//  PrintPartyWatch Watch App
//
//  Reusable circular progress indicator used across the watch UI. Shows the
//  percentage while a job is active, and the stage glyph otherwise.
//

import SwiftUI
import PrintPartyKit

struct ProgressRingView: View {
    let state: PrintJobState
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle()
                .stroke(state.stage.tint.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(state.progressPercent / 100, 0), 1)))
                .stroke(state.stage.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: state.progressPercent)

            if state.stage.isActive {
                VStack(spacing: 0) {
                    Text("\(Int(state.progressPercent))")
                        .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                    Text("%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: state.stage.symbolName)
                    .font(.title2)
                    .foregroundStyle(state.stage.tint)
            }
        }
    }
}
