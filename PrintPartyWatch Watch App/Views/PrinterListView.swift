//
//  PrinterListView.swift
//  PrintPartyWatch Watch App
//
//  Root screen: the printers the iPhone is tracking, each with a glanceable
//  stage + progress. Tapping a row opens the detail screen.
//

import SwiftUI
import PrintPartyKit

struct PrinterListView: View {
    @State private var sync = PhoneSyncService.shared

    var body: some View {
        NavigationStack {
            Group {
                if sync.snapshot.printers.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sync.snapshot.printers, id: \.printerId) { state in
                            NavigationLink(value: state.printerId) {
                                PrinterRow(state: state)
                            }
                        }
                        if let footer = stalenessFooter {
                            Text(footer)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Printers")
            .navigationDestination(for: UUID.self) { printerId in
                PrinterDetailView(printerId: printerId)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Printers", systemImage: "printer")
        } description: {
            Text("Open PrintParty on your iPhone to add a printer.")
        }
    }

    /// Show "last updated" when data is stale or the phone is unreachable, so a
    /// frozen value is never mistaken for live telemetry.
    private var stalenessFooter: String? {
        let age = Date.now.timeIntervalSince(sync.snapshot.generatedAt)
        guard !sync.isPhoneReachable || age > 60 else { return nil }
        guard sync.snapshot.generatedAt > .distantPast else { return nil }
        let formatted = sync.snapshot.generatedAt.formatted(.relative(presentation: .named))
        return "Updated \(formatted)"
    }
}

private struct PrinterRow: View {
    let state: PrintJobState

    var body: some View {
        HStack(spacing: 12) {
            ProgressRingView(state: state, lineWidth: 4)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.printerDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.substageMessage ?? state.stage.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
