//
//  PrintersListView.swift
//  PrintParty
//

import SwiftUI
import SwiftData

struct PrintersListView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Printer.createdAt) private var printers: [Printer]

    @State private var showAddBambuSheet = false
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
        .sheet(isPresented: $showAddBambuSheet) {
            AddBambuPrinterSheet()
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
            Text("Add a printer to start tracking print progress with a Live Activity.")
        } actions: {
            VStack(spacing: 12) {
                Button {
                    showAddBambuSheet = true
                } label: {
                    Label("Add Bambu Lab A1 Mini", systemImage: "printer.fill")
                }
                .buttonStyle(.borderedProminent)

            }
        }
    }

    private var list: some View {
        List {
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
            Menu {
                Button {
                    showAddBambuSheet = true
                } label: {
                    Label("Bambu A1 Mini (LAN direct)", systemImage: "printer.fill")
                }
                Button {
                    showAddGatewayPrinterSheet = true
                } label: {
                    Label("Via Gateway", systemImage: "server.rack")
                }
                .disabled(gateways.isEmpty)

            } label: {
                Label("Add Printer", systemImage: "plus")
            }
        }
    }

    // MARK: Actions

    /// Pre-populate the registry's gateway URL cache so the adapter factory
    /// can resolve gatewayId → baseURL without a SwiftData fetch.
    private func syncGatewayURLs() {
        for gw in gateways {
            if let url = URL(string: gw.baseURL) {
                registry.cacheGatewayURL(gatewayId: gw.gatewayId, baseURL: url)
            }
            if let relayURLString = gw.relayURL,
               let relayURL = URL(string: relayURLString) {
                registry.cacheGatewayRelayURL(gatewayId: gw.gatewayId, relayURL: relayURL)
            }
        }
    }

    private func deletePrinters(at offsets: IndexSet) {
        for index in offsets {
            let printer = printers[index]
            registry.unregister(printerId: printer.id)
            if printer.adapterKind == .bambuLabA1Mini {
                KeychainStore.delete(
                    KeychainStore.bambuAccessCodeAccount(printerId: printer.id)
                )
            }
            modelContext.delete(printer)
        }
    }
}

#Preview {
    PrintersListView()
        .modelContainer(for: [Printer.self, Gateway.self], inMemory: true)
}
