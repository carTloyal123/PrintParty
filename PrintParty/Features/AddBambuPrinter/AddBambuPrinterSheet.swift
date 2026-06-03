//
//  AddBambuPrinterSheet.swift
//  PrintParty
//
//  Onboarding form for a Bambu Lab A1 Mini (LAN mode).
//
//  Stores host + serial on the SwiftData Printer and the LAN access code
//  in Keychain. The credentials are then read by BambuLanAdapter when the
//  AdapterRegistry registers this printer.
//
//  Until the MQTT client lands the printer will show as Offline; the form
//  is still useful end-to-end for verifying persistence + Keychain.
//

import SwiftUI
import SwiftData

struct AddBambuPrinterSheet: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = "Bambu A1 Mini"
    @State private var host: String = ""
    @State private var serial: String = ""
    @State private var accessCode: String = ""
    @State private var revealCode: Bool = false

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !serial.trimmingCharacters(in: .whitespaces).isEmpty
            && !accessCode.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Display name", text: $displayName)
                        .textInputAutocapitalization(.words)
                }

                Section {
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
                        Button {
                            revealCode.toggle()
                        } label: {
                            Image(systemName: revealCode ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Find these on your A1 Mini:")
                        Text("• Settings → General → Device info — serial number.")
                        Text("• Settings → WLAN — local IP address.")
                        Text("• Settings → General → LAN Only Mode — access code (and toggle LAN Only Mode on).")
                    }
                    .font(.caption)
                }

                Section {
                    Label {
                        Text("Credentials never leave your device. The access code is stored in the iOS Keychain.")
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                }
            }
            .navigationTitle("Add Bambu A1 Mini")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let printer = Printer(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            modelName: "Bambu Lab A1 Mini",
            adapterKind: .bambuLabA1Mini,
            host: host.trimmingCharacters(in: .whitespaces),
            serial: serial.trimmingCharacters(in: .whitespaces)
        )

        // Stash secret in Keychain BEFORE inserting the printer, so that
        // AdapterRegistry can find it when SwiftData notifies us of the new row.
        let trimmedCode = accessCode.trimmingCharacters(in: .whitespaces)
        KeychainStore.set(
            trimmedCode,
            for: KeychainStore.bambuAccessCodeAccount(printerId: printer.id)
        )

        modelContext.insert(printer)
        dismiss()
    }
}

#Preview {
    AddBambuPrinterSheet()
        .modelContainer(for: Printer.self, inMemory: true)
}
