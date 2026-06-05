//
//  GatewayDetailView.swift
//  PrintParty
//
//  Management screen for a paired gateway. Shows connection status, gateway
//  info, and the list of printers registered on that gateway. Users can:
//
//  - See which printers are on the gateway and their current status
//  - Add a gateway printer to this device with one tap
//  - Remove a printer from the gateway entirely
//

import SwiftUI
import SwiftData

struct GatewayDetailView: View {

    let gateway: Gateway

    @Environment(\.modelContext) private var modelContext
    @Query private var localPrinters: [Printer]

    @State private var remotePrinters: [RemotePrinter] = []
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var printerToDelete: RemotePrinter?

    private var monitor: GatewayHealthMonitor { .shared }
    private var connectionStatus: GatewayConnectionStatus {
        monitor.status(for: gateway.gatewayId)
    }

    struct RemotePrinter: Decodable, Identifiable {
        let id: UUID
        let displayName: String
        let modelName: String
        let stage: String
        let progressPercent: Double
    }

    /// Printers from this gateway that are already tracked locally.
    private var localRemoteIds: Set<UUID> {
        Set(
            localPrinters
                .filter { $0.gatewayId == gateway.gatewayId }
                .compactMap(\.remotePrinterId)
        )
    }

    var body: some View {
        List {
            gatewayInfoSection
            printersSection
        }
        .navigationTitle(gateway.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            GatewayHealthMonitor.shared.refresh()
            await fetchPrinters()
        }
        .task {
            GatewayHealthMonitor.shared.refresh()
            await fetchPrinters()
        }
        .alert("Remove Printer", isPresented: showDeleteAlert, presenting: printerToDelete) { printer in
            Button("Remove from Gateway", role: .destructive) {
                Task { await deleteRemotePrinter(printer) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { printer in
            Text("This will stop the gateway's connection to \"\(printer.displayName)\" and remove it. You can re-add it later.")
        }
    }

    private var showDeleteAlert: Binding<Bool> {
        Binding(
            get: { printerToDelete != nil },
            set: { if !$0 { printerToDelete = nil } }
        )
    }

    // MARK: - Gateway info

    private var gatewayInfoSection: some View {
        Section {
            LabeledContent("LAN") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(lanStatusColor)
                        .frame(width: 8, height: 8)
                    lanStatusText
                }
            }
            LabeledContent("Relay") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(relayStatusColor)
                        .frame(width: 8, height: 8)
                    relayStatusText
                }
            }
            LabeledContent("URL") {
                Text(gateway.baseURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let relayURL = gateway.relayURL {
                LabeledContent("Relay URL") {
                    Text(relayURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            LabeledContent("Paired") {
                Text(gateway.pairedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Gateway")
        }
    }

    private var lanStatusColor: Color {
        switch connectionStatus {
        case .lanOnline:         return .green
        case .checking:          return .gray
        case .unknown:           return .gray
        default:                 return .red
        }
    }

    @ViewBuilder
    private var lanStatusText: some View {
        switch connectionStatus {
        case .lanOnline(let v):
            if v != "live" {
                Text("Online (v\(v))").foregroundStyle(.green)
            } else {
                Text("Online").foregroundStyle(.green)
            }
        case .checking, .unknown:
            ProgressView().controlSize(.small)
        default:
            Text("Unreachable").foregroundStyle(.red)
        }
    }

    private var relayStatusColor: Color {
        switch connectionStatus {
        case .lanOfflineRelayOnline:  return .blue
        case .lanOfflineRelayUnknown: return .gray
        case .lanOnline:             return .secondary // not needed when LAN is up
        default:
            return gateway.relayURL == nil ? .secondary : .red
        }
    }

    @ViewBuilder
    private var relayStatusText: some View {
        if gateway.relayURL == nil {
            Text("Not configured").foregroundStyle(.secondary)
        } else {
            switch connectionStatus {
            case .lanOnline:
                Text("Available").foregroundStyle(.secondary)
            case .lanOfflineRelayOnline:
                Text("Connected").foregroundStyle(.blue)
            case .lanOfflineRelayUnknown:
                ProgressView().controlSize(.small)
            case .offline:
                Text("Unreachable").foregroundStyle(.red)
            case .checking, .unknown:
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Printers section

    @ViewBuilder
    private var printersSection: some View {
        Section {
            if isFetching && remotePrinters.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading printers\u{2026}")
                        .foregroundStyle(.secondary)
                }
            } else if let fetchError {
                Label(fetchError, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if remotePrinters.isEmpty {
                Text("No printers registered on this gateway.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(remotePrinters) { printer in
                    printerRow(printer)
                }
            }
        } header: {
            HStack {
                Text("Printers")
                Spacer()
                if isFetching && !remotePrinters.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
        } footer: {
            if !remotePrinters.isEmpty {
                Text("Swipe left on a printer to remove it from the gateway. Printers not yet on this device show a \(Image(systemName: "plus.circle.fill")) button to add them.")
            }
        }
    }

    private func printerRow(_ printer: RemotePrinter) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(printer.displayName)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(printer.modelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    stageBadge(printer.stage)
                    if printer.stage == "printing" {
                        Text("\(Int(printer.progressPercent))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            if localRemoteIds.contains(printer.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Already on this device")
            } else {
                Button {
                    addLocally(printer)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Add to this device")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                printerToDelete = printer
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func stageBadge(_ stage: String) -> some View {
        let (label, color): (String, Color) = {
            switch stage {
            case "printing":  return ("Printing", .blue)
            case "preparing": return ("Preparing", .orange)
            case "paused":    return ("Paused", .yellow)
            case "idle":      return ("Idle", .gray)
            case "done":      return ("Done", .green)
            case "failed":    return ("Failed", .red)
            case "offline":   return ("Offline", .red)
            default:          return (stage.capitalized, .gray)
            }
        }()
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Actions

    /// Empty payload for WS requests that need no parameters.
    private struct EmptyPayload: Encodable {}

    private func fetchPrinters() async {
        isFetching = true
        fetchError = nil
        defer { isFetching = false }

        guard let client = AdapterRegistry.shared.gatewayClient(for: gateway.gatewayId) else {
            fetchError = "No connection to gateway."
            return
        }

        do {
            let data = try await client.request("printers.list", payload: EmptyPayload())
            remotePrinters = try JSONDecoder().decode([RemotePrinter].self, from: data)
        } catch {
            fetchError = "Could not fetch printers: \(error.localizedDescription)"
        }
    }

    private func addLocally(_ printer: RemotePrinter) {
        if let url = URL(string: gateway.baseURL) {
            AdapterRegistry.shared.cacheGatewayURL(
                gatewayId: gateway.gatewayId,
                baseURL: url
            )
        }

        let local = Printer(
            displayName: printer.displayName,
            modelName: printer.modelName,
            adapterKind: .gateway,
            gatewayId: gateway.gatewayId,
            remotePrinterId: printer.id
        )
        modelContext.insert(local)
    }

    private func deleteRemotePrinter(_ printer: RemotePrinter) async {
        struct RemovePayload: Encodable {
            let printerId: UUID
        }

        guard let client = AdapterRegistry.shared.gatewayClient(for: gateway.gatewayId) else { return }

        do {
            let _ = try await client.request("printers.remove", payload: RemovePayload(printerId: printer.id))
        } catch {
            return
        }

        // Remove from remote list
        remotePrinters.removeAll { $0.id == printer.id }

        // Also remove the local Printer record if one exists
        let printerId = printer.id
        let gatewayId = gateway.gatewayId
        let descriptor = FetchDescriptor<Printer>(
            predicate: #Predicate {
                $0.gatewayId == gatewayId && $0.remotePrinterId == printerId
            }
        )
        if let locals = try? modelContext.fetch(descriptor) {
            for local in locals {
                AdapterRegistry.shared.unregister(printerId: local.id)
                modelContext.delete(local)
            }
        }
    }
}

#Preview {
    NavigationStack {
        GatewayDetailView(
            gateway: Gateway(
                gatewayId: UUID().uuidString,
                displayName: "Test Gateway",
                baseURL: "http://localhost:8080"
            )
        )
    }
    .modelContainer(for: [Printer.self, Gateway.self], inMemory: true)
}
