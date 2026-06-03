//
//  GatewayDetailView.swift
//  PrintParty
//
//  Management screen for a paired gateway. Shows connection status, gateway
//  info, and the list of printers registered on that gateway. Users can:
//
//  - See which printers are on the gateway and their current status
//  - Add a gateway printer to this device with one tap
//  - Remove a printer from the gateway entirely (stops MQTT, deletes config)
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
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var printerToDelete: RemotePrinter?

    enum ConnectionStatus: Equatable {
        case unknown, checking, online(version: String), offline(reason: String)
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
            await refresh()
        }
        .task {
            await refresh()
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
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    statusText
                }
            }
            LabeledContent("URL") {
                Text(gateway.baseURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
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

    private var statusColor: Color {
        switch connectionStatus {
        case .unknown, .checking: return .gray
        case .online: return .green
        case .offline: return .red
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch connectionStatus {
        case .unknown: Text("Unknown").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case .online(let v): Text("Online (v\(v))").foregroundStyle(.green)
        case .offline(let r): Text(r).foregroundStyle(.red).lineLimit(1)
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

    private func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await checkHealth() }
            group.addTask { await fetchPrinters() }
        }
    }

    private func checkHealth() async {
        guard let url = URL(string: gateway.baseURL) else {
            connectionStatus = .offline(reason: "Invalid URL")
            return
        }
        connectionStatus = .checking
        do {
            let resp = try await PairingClient.ping(baseURL: url)
            if resp.gatewayId != gateway.gatewayId {
                connectionStatus = .offline(reason: "Gateway was reset — re-pair required")
            } else {
                connectionStatus = .online(version: resp.version)
            }
        } catch {
            connectionStatus = .offline(reason: error.localizedDescription)
        }
    }

    private func fetchPrinters() async {
        guard let baseURL = URL(string: gateway.baseURL) else { return }

        isFetching = true
        fetchError = nil
        defer { isFetching = false }

        let url = baseURL.appendingPathComponent("v1/printers")
        var req = URLRequest(url: url)
        req.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                fetchError = "Gateway returned an error."
                return
            }
            remotePrinters = try JSONDecoder().decode([RemotePrinter].self, from: data)
        } catch {
            fetchError = "Could not reach gateway."
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
        guard let baseURL = URL(string: gateway.baseURL) else { return }

        let url = baseURL.appendingPathComponent("v1/printers/\(printer.id.uuidString)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
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
        } catch {
            // Silently fail — the printer list will refresh on pull-to-refresh
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
