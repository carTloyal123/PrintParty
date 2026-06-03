//
//  SettingsView.swift
//  PrintParty
//
//  Top-level settings screen. Hosts the Gateways section with live
//  connection status indicators.
//

import SwiftUI
import SwiftData

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Gateway.pairedAt) private var gateways: [Gateway]

    @State private var showAddGatewaySheet = false
    @State private var showResetConfirmation = false
    @Query private var allPrinters: [Printer]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if gateways.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No gateways paired")
                                .font(.subheadline.weight(.semibold))
                            Text("Pair a self-hosted PrintParty gateway to track prints when you're away from your home network.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(gateways) { gateway in
                            NavigationLink {
                                GatewayDetailView(gateway: gateway)
                            } label: {
                                GatewayRow(gateway: gateway)
                            }
                        }
                        .onDelete(perform: deleteGateways)
                    }
                } header: {
                    Text("Gateways")
                } footer: {
                    Text("Gateways are open-source PrintParty servers you (or someone you trust) run at home, on a NAS, or on a small VPS. They talk to your printers and securely relay Live Activity updates to your phone.")
                        .font(.caption)
                }

                Section {
                    Button {
                        showAddGatewaySheet = true
                    } label: {
                        Label("Pair a Gateway\u{2026}", systemImage: "plus.circle.fill")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset All Data", systemImage: "trash")
                    }
                    Button(role: .destructive) {
                        Task { await LiveActivityCoordinator.shared.endAll() }
                    } label: {
                        Label("End All Live Activities", systemImage: "xmark.circle")
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Reset deletes all printers, gateways, pairing keys, and preferences. You'll need to re-pair your gateway and re-add printers.")
                        .font(.caption)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddGatewaySheet) {
                AddGatewaySheet()
            }
            .alert("Reset All Data?", isPresented: $showResetConfirmation) {
                Button("Reset", role: .destructive) { resetAllData() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will delete all printers, gateways, pairing keys, Live Activity preferences, and end all active Live Activities. This cannot be undone.")
            }
        }
    }

    private func deleteGateways(at offsets: IndexSet) {
        for index in offsets {
            let gateway = gateways[index]
            let gatewayId = gateway.gatewayId

            // Cascade delete: remove all printers associated with this gateway.
            let associatedPrinters = allPrinters.filter { $0.gatewayId == gatewayId }
            for printer in associatedPrinters {
                AdapterRegistry.shared.unregister(printerId: printer.id)
                modelContext.delete(printer)
            }

            // Delete the gateway's shared key from Keychain.
            KeychainStore.delete(
                KeychainStore.gatewaySharedKeyAccount(gatewayId: gatewayId)
            )
            modelContext.delete(gateway)
        }
    }

    private func resetAllData() {
        // 1. End all Live Activities
        Task { await LiveActivityCoordinator.shared.endAll() }

        // 2. Unregister all adapters
        for printer in allPrinters {
            AdapterRegistry.shared.unregister(printerId: printer.id)
        }

        // 3. Delete Keychain items for each gateway
        for gateway in gateways {
            KeychainStore.delete(
                KeychainStore.gatewaySharedKeyAccount(gatewayId: gateway.gatewayId)
            )
        }

        // 4. Delete all SwiftData records
        for printer in allPrinters { modelContext.delete(printer) }
        for gateway in gateways { modelContext.delete(gateway) }

        // 5. Clear UserDefaults (Live Activity preferences, device ID)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: LiveActivityCoordinator.lingerDurationKey)
        defaults.removeObject(forKey: LiveActivityCoordinator.lingerEnabledKey)
        defaults.removeObject(forKey: LiveActivityCoordinator.disabledPrinterIdsKey)
        defaults.removeObject(forKey: "com.clengineering.PrintParty.deviceId")
    }
}

// MARK: - Gateway Row driven by GatewayHealthMonitor

private struct GatewayRow: View {
    let gateway: Gateway

    private var monitor: GatewayHealthMonitor { .shared }

    private var status: GatewayConnectionStatus {
        monitor.status(for: gateway.gatewayId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(gateway.displayName)
                        .font(.body.weight(.semibold))
                    Text(gateway.baseURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                statusBadge
            }
            HStack {
                Text("Paired \(gateway.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                statusDetail
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Status indicators

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(status.dotColor)
            .frame(width: 10, height: 10)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .unknown:
            EmptyView()
        case .checking, .lanOfflineRelayUnknown:
            ProgressView()
                .controlSize(.small)
        case .lanOnline(let version):
            if version != "live" {
                Text("v\(version)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .lanOfflineRelayOnline:
            Label("Relay", systemImage: "globe")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .offline:
            Image(systemName: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch status {
        case .unknown:
            Text("Checking\u{2026}")
        case .checking:
            Text("Connecting\u{2026}")
        case .lanOnline(let version):
            if version != "live" {
                Text("Connected")
                    .foregroundStyle(.green)
            } else {
                Text("Connected (via adapter)")
                    .foregroundStyle(.green)
            }
        case .lanOfflineRelayOnline:
            Text("LAN offline \u{2022} Relay connected")
                .foregroundStyle(.blue)
        case .lanOfflineRelayUnknown:
            Text("LAN offline \u{2022} Checking relay\u{2026}")
                .foregroundStyle(.secondary)
        case .offline(let reason):
            Text(reason)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Printer.self, Gateway.self], inMemory: true)
}
