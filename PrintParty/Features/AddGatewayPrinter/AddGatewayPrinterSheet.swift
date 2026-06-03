//
//  AddGatewayPrinterSheet.swift
//  PrintParty
//
//  Adds a printer from a paired gateway. Two paths:
//
//  A) Quick-add: the sheet fetches printers already registered on the
//     gateway via the WebSocket `printers.list` request and shows them
//     in a list. The user taps one to add it locally.
//
//  B) Manual: the user fills in printer details (host, serial, access code)
//     which are sent to the gateway via `printers.register` to register
//     a brand-new printer.
//
//  Flow A is the common case (printer was configured on the gateway once,
//  now every iOS device can add it with a single tap).
//

import SwiftUI
import SwiftData

struct AddGatewayPrinterSheet: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Gateway.pairedAt) private var gateways: [Gateway]
    @Query private var localPrinters: [Printer]

    @State private var selectedGateway: Gateway?

    // Remote printer list state
    @State private var remotePrinters: [RemotePrinter] = []
    @State private var isFetching = false
    @State private var fetchError: String?

    // Manual registration state
    @State private var showManualForm = false
    @State private var displayName = "Bambu A1 Mini"
    @State private var host = ""
    @State private var serial = ""
    @State private var accessCode = ""
    @State private var revealCode = false
    @State private var isRegistering = false
    @State private var lastError: String?

    private var canSubmitManual: Bool {
        !isRegistering
            && selectedGateway != nil
            && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !serial.trimmingCharacters(in: .whitespaces).isEmpty
            && !accessCode.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Remote printers that aren't already added locally for the selected gateway.
    private var availablePrinters: [RemotePrinter] {
        guard let gw = selectedGateway else { return [] }
        let existingRemoteIds = Set(
            localPrinters
                .filter { $0.gatewayId == gw.gatewayId }
                .compactMap(\.remotePrinterId)
        )
        return remotePrinters.filter { !existingRemoteIds.contains($0.id) }
    }

    /// Remote printers that are already added locally.
    private var alreadyAddedPrinters: [RemotePrinter] {
        guard let gw = selectedGateway else { return [] }
        let existingRemoteIds = Set(
            localPrinters
                .filter { $0.gatewayId == gw.gatewayId }
                .compactMap(\.remotePrinterId)
        )
        return remotePrinters.filter { existingRemoteIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if gateways.isEmpty {
                    Section {
                        Label("No gateways paired. Pair a gateway in Settings first.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } else {
                    gatewayPickerSection
                    availablePrintersSection
                    manualFormSection
                }

                if let lastError {
                    Section {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Add via Gateway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isRegistering)
                }
            }
            .onAppear {
                if selectedGateway == nil, let first = gateways.first {
                    selectedGateway = first
                }
            }
            .onChange(of: selectedGateway) { _, _ in
                Task { await fetchRemotePrinters() }
            }
            .task {
                // Fetch on initial appear if a gateway is already selected.
                if selectedGateway != nil {
                    await fetchRemotePrinters()
                }
            }
        }
    }

    // MARK: - Gateway picker

    private var gatewayPickerSection: some View {
        Section("Gateway") {
            Picker("Gateway", selection: $selectedGateway) {
                Text("Select\u{2026}").tag(nil as Gateway?)
                ForEach(gateways) { gw in
                    Text(gw.displayName).tag(gw as Gateway?)
                }
            }
        }
    }

    // MARK: - Available printers from gateway

    @ViewBuilder
    private var availablePrintersSection: some View {
        if selectedGateway != nil {
            Section {
                if isFetching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading printers from gateway\u{2026}")
                            .foregroundStyle(.secondary)
                    }
                } else if let fetchError {
                    Label(fetchError, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Button("Retry") {
                        Task { await fetchRemotePrinters() }
                    }
                } else if remotePrinters.isEmpty {
                    Label("No printers registered on this gateway yet.", systemImage: "printer")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else if availablePrinters.isEmpty && !alreadyAddedPrinters.isEmpty {
                    Label("All printers from this gateway are already added.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(availablePrinters, id: \.id) { remote in
                        Button {
                            addRemotePrinter(remote)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(remote.displayName)
                                        .foregroundStyle(.primary)
                                    Text(remote.modelName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.blue)
                                    .imageScale(.large)
                            }
                        }
                    }
                }
            } header: {
                Text("Available on Gateway")
            } footer: {
                if !availablePrinters.isEmpty {
                    Text("Tap a printer to add it. No additional configuration needed.")
                }
            }

            if !alreadyAddedPrinters.isEmpty {
                Section("Already Added") {
                    ForEach(alreadyAddedPrinters, id: \.id) { remote in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(remote.displayName)
                                    .foregroundStyle(.primary)
                                Text(remote.modelName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Manual registration form

    private var manualFormSection: some View {
        Section {
            DisclosureGroup("Register a new printer on gateway", isExpanded: $showManualForm) {
                TextField("Display name", text: $displayName)
                TextField("IP address or hostname", text: $host)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                TextField("Device serial number", text: $serial)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                HStack {
                    if revealCode {
                        TextField("LAN access code", text: $accessCode)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField("LAN access code", text: $accessCode)
                    }
                    Button { revealCode.toggle() } label: {
                        Image(systemName: revealCode ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await registerManual() }
                } label: {
                    HStack {
                        Spacer()
                        if isRegistering { ProgressView() } else { Text("Register & Add") }
                        Spacer()
                    }
                }
                .disabled(!canSubmitManual)

                Label("The printer credentials are sent to the gateway and stored there. They are NOT stored on this device.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Quick-add from gateway list

    private func addRemotePrinter(_ remote: RemotePrinter) {
        guard let gateway = selectedGateway else { return }

        // Cache gateway URL so the adapter factory can find it.
        if let url = URL(string: gateway.baseURL) {
            AdapterRegistry.shared.cacheGatewayURL(
                gatewayId: gateway.gatewayId,
                baseURL: url
            )
        }

        let printer = Printer(
            displayName: remote.displayName,
            modelName: remote.modelName,
            adapterKind: .gateway,
            gatewayId: gateway.gatewayId,
            remotePrinterId: remote.id
        )
        modelContext.insert(printer)
        dismiss()
    }

    // MARK: - Fetch printers from gateway

    struct RemotePrinter: Decodable, Identifiable {
        let id: UUID
        let displayName: String
        let modelName: String
        let stage: String
        let progressPercent: Double
    }

    /// Empty payload for WS requests that need no parameters.
    private struct EmptyPayload: Encodable {}

    private func fetchRemotePrinters() async {
        guard let gateway = selectedGateway else {
            remotePrinters = []
            return
        }

        isFetching = true
        fetchError = nil
        defer { isFetching = false }

        guard let adapter = AdapterRegistry.shared.gatewayAdapter(for: gateway.gatewayId),
              adapter.connectionMode != .disconnected else {
            fetchError = "Not connected to gateway."
            remotePrinters = []
            return
        }

        do {
            let data = try await adapter.request("printers.list", payload: EmptyPayload())
            remotePrinters = try JSONDecoder().decode([RemotePrinter].self, from: data)
        } catch {
            fetchError = "Could not fetch printers: \(error.localizedDescription)"
            remotePrinters = []
        }
    }

    // MARK: - Manual registration

    private struct RegisterRequest: Encodable {
        let displayName: String
        let modelName: String
        let host: String
        let serial: String
        let accessCode: String
    }

    private struct RegisterResponse: Decodable {
        let printerId: UUID
        let status: String
    }

    private func registerManual() async {
        guard let gateway = selectedGateway else { return }

        isRegistering = true
        lastError = nil
        defer { isRegistering = false }

        let body = RegisterRequest(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            modelName: "Bambu Lab A1 Mini",
            host: host.trimmingCharacters(in: .whitespaces),
            serial: serial.trimmingCharacters(in: .whitespaces),
            accessCode: accessCode.trimmingCharacters(in: .whitespaces)
        )

        guard let adapter = AdapterRegistry.shared.gatewayAdapter(for: gateway.gatewayId),
              adapter.connectionMode != .disconnected else {
            lastError = "Not connected to gateway."
            return
        }

        do {
            let data = try await adapter.request("printers.register", payload: body)
            let resp = try JSONDecoder().decode(RegisterResponse.self, from: data)

            // Cache gateway URL in the registry so the adapter factory can find it.
            if let baseURL = URL(string: gateway.baseURL) {
                AdapterRegistry.shared.cacheGatewayURL(
                    gatewayId: gateway.gatewayId,
                    baseURL: baseURL
                )
            }

            // Create local Printer record.
            let printer = Printer(
                displayName: body.displayName,
                modelName: body.modelName,
                gatewayId: gateway.gatewayId,
                remotePrinterId: resp.printerId
            )
            modelContext.insert(printer)
            dismiss()

        } catch {
            lastError = error.localizedDescription
        }
    }
}

#Preview {
    AddGatewayPrinterSheet()
        .modelContainer(for: [Printer.self, Gateway.self], inMemory: true)
}
