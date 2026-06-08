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
import PrintPartyKit

struct AddGatewaySheet: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var baseURLString: String = "http://localhost:8080"
    @State private var code: String = ""
    @State private var isPairing: Bool = false
    @State private var lastError: String?
    @State private var pingResult: PingState = .idle

    @State private var browser = GatewayBrowser()
    @State private var showQRScanner = false
    @State private var showCameraDeniedAlert = false
    @State private var autoPairNotice: String?
    @Query(sort: \Gateway.pairedAt) private var existingGateways: [Gateway]

    /// gatewayId prefixes (first 8 chars) of already-paired gateways, matching
    /// the `gid` advertised in the Bonjour TXT record.
    private var pairedGatewayIds: Set<String> {
        Set(existingGateways.map { String($0.gatewayId.prefix(8)) })
    }

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
                    DiscoveredGatewayList(
                        gateways: browser.discoveredGateways,
                        pairedGatewayIds: pairedGatewayIds,
                        onSelect: { gw in
                            if let url = gw.baseURL {
                                baseURLString = url.absoluteString
                            }
                        },
                        isBrowsing: browser.isBrowsing
                    )
                } header: {
                    Text("Nearby Gateways")
                }

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
                    Button {
                        showQRScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(isPairing)
                } footer: {
                    Text("Scan the QR code displayed in your gateway's terminal to fill in both fields automatically.")
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
        .overlay(alignment: .bottom) {
            if let autoPairNotice {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(autoPairNotice)
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeInOut, value: autoPairNotice)
        .sheet(isPresented: $showQRScanner) {
            NavigationStack {
                QRScannerView(
                    onScanned: { url, code in
                        applyScanned(url: url, code: code)
                    },
                    onPermissionDenied: {
                        showQRScanner = false
                        showCameraDeniedAlert = true
                    }
                )
                .ignoresSafeArea()
                .navigationTitle("Scan Gateway QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showQRScanner = false }
                    }
                }
            }
        }
        .alert("Camera Access Needed", isPresented: $showCameraDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PrintParty needs camera access to scan pairing QR codes. You can still pair by entering the URL and code manually.")
        }
        .onAppear {
            browser.startBrowsing()
            // Pre-fill from a `printparty://` deep link, if one is pending.
            if let pending = DeepLinkRouter.shared.pendingPairing {
                baseURLString = pending.url
                code = pending.code
                DeepLinkRouter.shared.pendingPairing = nil
            }
        }
        .onDisappear { browser.stopBrowsing() }
    }

    /// Apply values captured from a QR scan / deep link to the form fields,
    /// then auto-pair so the happy path is fully zero-typing. A short delay lets
    /// the user see the fields populate before pairing kicks off.
    private func applyScanned(url: String, code: String) {
        baseURLString = url
        self.code = code.uppercased().filter { !$0.isWhitespace }
        guard canSubmit else { return }
        autoPairNotice = "Pairing\u{2026}"
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if let host = URL(string: baseURLString)?.host {
                autoPairNotice = "Pairing with \(host)\u{2026}"
            }
            await pair()
            autoPairNotice = nil
        }
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

            // Store group key in Keychain if the gateway provided one.
            if let groupKey = result.groupKey {
                KeychainStore.set(
                    groupKey.base64EncodedString(),
                    for: KeychainStore.gatewayGroupKeyAccount(gatewayId: result.gatewayId)
                )
            }

            // Persist gateway record.
            let gateway = Gateway(
                gatewayId: result.gatewayId,
                displayName: result.gatewayName,
                baseURL: baseURLString,
                relayURL: result.relayURL,
                pairedAt: .now
            )
            modelContext.insert(gateway)

            // Start the shared WebSocket connection for this gateway immediately.
            // This must happen before syncPrinters so the WS is available.
            AdapterRegistry.shared.registerGateway(
                gatewayId: result.gatewayId,
                baseURL: url,
                relayURL: result.relayURL.flatMap { URL(string: $0) }
            )

            // Auto-import any printers already registered on the gateway.
            // Don't block dismiss on this — it can complete in the background.
            let gw = gateway
            Task {
                await GatewaySyncService.syncPrinters(
                    gateway: gw,
                    modelContext: modelContext
                )
            }

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
