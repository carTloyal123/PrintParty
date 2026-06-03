//
//  AddGatewaySheet.swift
//  PrintParty
//
//  Pairing form for a self-hosted gateway.
//
//  Flow:
//   1. User enters the gateway URL (Mac IP + port, or localhost on Simulator)
//      and the 8-character pairing code printed by the gateway at startup.
//   2. App optionally pings /healthz to confirm reachability.
//   3. App calls PairingClient.pair which runs X25519 ECDH + HKDF.
//   4. Resulting SymmetricKey is stored in Keychain.
//   5. Gateway record is inserted into SwiftData.
//

import SwiftUI
import SwiftData
import CryptoKit
import UIKit

struct AddGatewaySheet: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var baseURLString: String = "http://localhost:8080"
    @State private var code: String = ""
    @State private var isPairing: Bool = false
    @State private var lastError: String?
    @State private var pingResult: PingState = .idle

    private enum PingState: Equatable {
        case idle
        case checking
        case ok(name: String, version: String)
        case failed(String)
    }

    private var canSubmit: Bool {
        !isPairing
            && URL(string: baseURLString) != nil
            && code.trimmingCharacters(in: .whitespaces).count == 8
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Gateway URL", text: $baseURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    HStack {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .disabled(URL(string: baseURLString) == nil || isPairing)
                        Spacer()
                        pingResultBadge
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Use http://localhost:8080 when the gateway runs on your Mac and the app runs in the Simulator. On a real device, use the Mac's LAN IP (e.g. http://192.168.1.42:8080).")
                        .font(.caption)
                }

                Section {
                    TextField("Pairing code (8 chars)", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onChange(of: code) { _, new in
                            // Strip whitespace; uppercase as user types.
                            code = new.uppercased().filter { !$0.isWhitespace }
                        }
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Printed in the gateway's terminal at startup. The code expires 5 minutes after it is generated and is single-use.")
                        .font(.caption)
                }

                if let lastError {
                    Section {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Label("The pairing handshake exchanges X25519 public keys over your local network. The derived shared key is stored only in this device's Keychain — the gateway never sees it.", systemImage: "lock.shield")
                        .font(.caption)
                }
            }
            .navigationTitle("Pair Gateway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isPairing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await pair() }
                    } label: {
                        if isPairing {
                            ProgressView()
                        } else {
                            Text("Pair")
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .interactiveDismissDisabled(isPairing)
    }

    // MARK: - Ping badge

    @ViewBuilder
    private var pingResultBadge: some View {
        switch pingResult {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView()
        case .ok(let name, _):
            Label(name, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    // MARK: - Actions

    private func testConnection() async {
        guard let url = URL(string: baseURLString) else { return }
        pingResult = .checking
        do {
            let resp = try await PairingClient.ping(baseURL: url)
            pingResult = .ok(name: resp.gatewayName, version: resp.version)
        } catch let error as PairingError {
            pingResult = .failed(error.localizedDescription)
        } catch {
            pingResult = .failed(error.localizedDescription)
        }
    }

    private func pair() async {
        guard let url = URL(string: baseURLString) else { return }
        let trimmedCode = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmedCode.count == 8 else { return }

        isPairing = true
        lastError = nil
        defer { isPairing = false }

        do {
            let result = try await PairingClient.pair(
                baseURL: url,
                code: trimmedCode,
                deviceId: deviceId(),
                deviceName: deviceName()
            )

            // Store shared key in Keychain (base64 of raw bytes).
            let keyData = result.sharedKey.withUnsafeBytes { Data($0) }
            KeychainStore.set(
                keyData.base64EncodedString(),
                for: KeychainStore.gatewaySharedKeyAccount(gatewayId: result.gatewayId)
            )

            // Persist gateway record.
            let gateway = Gateway(
                gatewayId: result.gatewayId,
                displayName: result.gatewayName,
                baseURL: baseURLString,
                relayURL: result.relayURL,
                pairedAt: .now
            )
            modelContext.insert(gateway)

            // Cache the URL so adapters can find it immediately.
            AdapterRegistry.shared.cacheGatewayURL(
                gatewayId: result.gatewayId,
                baseURL: url
            )

            // Cache the relay URL if the gateway provided one.
            if let relayURLString = result.relayURL,
               let relayURL = URL(string: relayURLString) {
                AdapterRegistry.shared.cacheGatewayRelayURL(
                    gatewayId: result.gatewayId,
                    relayURL: relayURL
                )
            }

            // Auto-import any printers already registered on the gateway.
            await GatewaySyncService.syncPrinters(
                gateway: gateway,
                modelContext: modelContext
            )

            dismiss()
        } catch let error as PairingError {
            lastError = error.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Device identity helpers

    /// Stable per-install device identifier. Persisted in UserDefaults so
    /// re-pairing the same gateway recognizes us across app launches.
    private func deviceId() -> String {
        let key = "com.clengineering.PrintParty.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    private func deviceName() -> String {
        UIDevice.current.name
    }
}

#Preview {
    AddGatewaySheet()
        .modelContainer(for: [Printer.self, Gateway.self], inMemory: true)
}
