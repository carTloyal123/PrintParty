//
//  PrintersListView.swift
//  PrintParty
//

import SwiftUI
import SwiftData

struct PrintersListView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Printer.createdAt) private var printers: [Printer]

    @State private var showAddGatewayPrinterSheet = false
    @State private var showSettingsSheet = false

    @Query(sort: \Gateway.pairedAt) private var gateways: [Gateway]

    private var registry: AdapterRegistry { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if printers.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Printers")
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showAddGatewayPrinterSheet) {
            AddGatewayPrinterSheet()
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
        }
        .onAppear {
            syncGatewayURLs()
            registry.sync(with: printers)
        }
        .onChange(of: printers) { _, newValue in
            registry.sync(with: newValue)
        }
        .task {
            // On launch, sync printers from all paired gateways.
            // This auto-imports printers registered on the gateway that
            // this device doesn't have local records for yet.
            await GatewaySyncService.syncAllGateways(
                gateways: gateways,
                modelContext: modelContext
            )
            registry.sync(with: printers)
        }
    }

    // MARK: Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Printers", systemImage: "printer")
        } description: {
            if gateways.isEmpty {
                Text("Pair a gateway in Settings, then add printers from it.")
            } else {
                Text("Add a printer from your gateway to start tracking print progress.")
            }
        } actions: {
            Button {
                showAddGatewayPrinterSheet = true
            } label: {
                Label("Add Printer via Gateway", systemImage: "server.rack")
            }
            .buttonStyle(.borderedProminent)
            .disabled(gateways.isEmpty)
        }
    }

    private var list: some View {
        List {
            connectionSummarySection
            ForEach(printers) { printer in
                NavigationLink {
                    PrinterDetailView(printer: printer)
                } label: {
                    PrinterRowView(printer: printer)
                }
            }
            .onDelete(perform: deletePrinters)
        }
    }

    // MARK: - Connection summary banner

    @ViewBuilder
    private var connectionSummarySection: some View {
        let phases = printers.map { registry.connectionPhase(for: $0) }
        let disconnectedCount = phases.filter {
            if case .disconnected = $0 { return true }
            return false
        }.count
        let connectingCount = phases.filter(\.isConnecting).count
        let relayCount = phases.filter { $0 == .connectedRelay }.count
        let pushCount = phases.filter { $0 == .push }.count

        if disconnectedCount > 0 {
            Section {
                Label(
                    "\(disconnectedCount) printer\(disconnectedCount == 1 ? "" : "s") offline",
                    systemImage: "wifi.slash"
                )
                .font(.subheadline)
                .foregroundStyle(.red)
            }
        } else if connectingCount > 0 {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(connectingCount) printer\(connectingCount == 1 ? "" : "s") connecting\u{2026}")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } else if pushCount > 0 {
            Section {
                Label(
                    "\(pushCount) printer\(pushCount == 1 ? "" : "s") showing push data",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
            }
        } else if relayCount > 0 {
            Section {
                Label(
                    "\(relayCount) printer\(relayCount == 1 ? "" : "s") connected via relay",
                    systemImage: "globe"
                )
                .font(.subheadline)
                .foregroundStyle(.blue)
            }
        }
        // All connected via LAN → no banner
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettingsSheet = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAddGatewayPrinterSheet = true
            } label: {
                Label("Add Printer", systemImage: "plus")
            }
            .disabled(gateways.isEmpty)
        }
    }

    // MARK: Actions

    /// Register gateways with the AdapterRegistry (starts WebSocket connections)
    /// and feed the GatewayHealthMonitor with the current gateway list.
    private func syncGatewayURLs() {
        var monitorGateways: [GatewayHealthMonitor.GatewayInfo] = []
        for gw in gateways {
            if let url = URL(string: gw.baseURL) {
                let relayURL = gw.relayURL.flatMap { URL(string: $0) }
                registry.registerGateway(
                    gatewayId: gw.gatewayId,
                    baseURL: url,
                    relayURL: relayURL
                )
                monitorGateways.append(GatewayHealthMonitor.GatewayInfo(
                    gatewayId: gw.gatewayId,
                    baseURL: url,
                    relayURL: relayURL
                ))
            }
        }
        GatewayHealthMonitor.shared.update(gateways: monitorGateways)
    }

    private func deletePrinters(at offsets: IndexSet) {
        for index in offsets {
            let printer = printers[index]
            registry.unregister(printerId: printer.id)
            modelContext.delete(printer)
        }
    }
}

#Preview {
    PrintersListView()
        .modelContainer(for: [Printer.self, Gateway.self], inMemory: true)
}
