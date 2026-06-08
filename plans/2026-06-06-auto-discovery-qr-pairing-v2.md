# Auto-Discovery & QR Code Pairing — Forge-Ready Implementation Plan

## Objective

Eliminate manual data entry during gateway pairing. Today users must type a URL like `http://192.168.1.42:8080` and an 8-character code. After this work:
- **Bonjour** discovers the gateway automatically (no URL typing)
- **QR code** captures both URL + code in one scan (zero typing)
- Combined flow: tap discovered gateway, scan QR, paired instantly

---

## Phase 1: Bonjour Discovery — Gateway Side

### Task 1.1: Create `BonjourAdvertiser`

**New file**: `gateway/Sources/PrintPartyGateway/Discovery/BonjourAdvertiser.swift`

Create an actor that publishes a `_printparty._tcp` Bonjour service using `NWListener` (Network framework). The gateway targets macOS 14+ (`Package.swift:7`) so `NWListener` is available.

```swift
import Foundation
import Network
import os

actor BonjourAdvertiser {
    private static let log = Logger(subsystem: "com.clengineering.PrintPartyGateway", category: "Bonjour")
    private var listener: NWListener?
    
    let gatewayId: String
    let gatewayName: String
    let version: String
    let port: UInt16
    
    init(gatewayId: String, gatewayName: String, version: String, port: UInt16) { ... }
    
    func start() {
        // Create NWListener on the specified port
        // Set service type to "_printparty._tcp"
        // Set service name to gatewayName
        // Set TXT record with keys: gid (first 8 chars of gatewayId), name, ver, path="/"
        // DO NOT include the pairing code in the TXT record
        // Start the listener
        // Log success/failure
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
    }
}
```

**TXT record format** (RFC 6763, each value < 255 bytes):

| Key | Value | Example |
|-----|-------|---------|
| `gid` | Gateway UUID (first 8 chars) | `a3f7c2e1` |
| `name` | Gateway display name | `Chris's Mac` |
| `ver` | Gateway version | `0.1.0` |
| `path` | API base path | `/` |

**Important**: The `NWListener` here is NOT for accepting connections — it's only for Bonjour advertisement. Set it up with a passive configuration that advertises the service but lets Vapor handle actual TCP connections. Use `NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)` and immediately cancel incoming connections in the `newConnectionHandler`, or use a minimal listener that only advertises.

**Alternative approach**: If `NWListener` conflicts with Vapor's port binding, use `NWListener` on port 0 (ephemeral) purely for service advertisement, and set the TXT record `port` field to the actual Vapor port. The iOS `NWBrowser` result includes the TXT record, so it can read the real port from there.

### Task 1.2: Wire into `Configure.swift`

**File**: `gateway/Sources/PrintPartyGateway/Configure.swift`

**Add env var** (after line 47, following the `Environment.get()` pattern used for `HOST`, `PORT`, `RELAY_URL`, `GATEWAY_NAME`):
```swift
let bonjourEnabled = Environment.get("BONJOUR_ENABLED")?.lowercased() != "false" // default true
```

**Create and store advertiser** (after line 101, before route registration at line 103):
```swift
var bonjourAdvertiser: BonjourAdvertiser? = nil
if bonjourEnabled {
    let advertiser = BonjourAdvertiser(
        gatewayId: gatewayId,
        gatewayName: gatewayName,
        version: "0.1.0",
        port: UInt16(port)
    )
    bonjourAdvertiser = advertiser
    Task { await advertiser.start() }
}
```

Store in `Application.storage` following the existing `StorageKey` pattern at `Configure.swift:234-244`:
```swift
struct BonjourKey: StorageKey { typealias Value = BonjourAdvertiser }
extension Application {
    var bonjourAdvertiser: BonjourAdvertiser? {
        get { storage[BonjourKey.self] }
        set { storage[BonjourKey.self] = newValue }
    }
}
```

**Add to lifecycle handler** (`Configure.swift:248-255`): The `GatewayLifecycleHandler` struct needs a `bonjourAdvertiser: BonjourAdvertiser?` property. In `shutdownAsync()`, call `await bonjourAdvertiser?.stop()`.

**Update startup banner** (inside the banner block at `Configure.swift:131-146`, after the "Gateway name" line ~139):
```
║  Bonjour:        advertising as _printparty._tcp    ║
```
Or `Bonjour: disabled` when `bonjourEnabled == false`.

### Task 1.3: Update `docker-compose.yml`

**File**: `docker-compose.yml`

Add `BONJOUR_ENABLED=false` to the environment section. Add a comment explaining that `network_mode: host` is required for Bonjour in Docker and that QR code pairing is the recommended approach for containerized deployments.

---

## Phase 2: Bonjour Discovery — iOS Side

### Task 2.1: Create `GatewayBrowser`

**New file**: `PrintParty/Core/Net/GatewayBrowser.swift`

An `@Observable` class that uses `NWBrowser` (Network framework) to browse for `_printparty._tcp` services.

```swift
import Foundation
import Network
import Observation

@MainActor
@Observable
final class GatewayBrowser {
    
    struct DiscoveredGateway: Identifiable, Equatable {
        let id: String          // gatewayId from TXT record (gid field)
        let name: String        // from TXT record (name field)
        let host: String        // resolved IP address
        let port: UInt16        // service port
        let version: String     // from TXT record (ver field)
        
        var baseURL: URL? {
            URL(string: "http://\(host):\(port)")
        }
    }
    
    private(set) var discoveredGateways: [DiscoveredGateway] = []
    private(set) var isBrowsing = false
    
    private var browser: NWBrowser?
    // Track NWBrowser results and resolve endpoints to IP addresses
    private var pendingResolutions: [NWEndpoint: NWConnection] = [:]
    
    func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true
        
        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_printparty._tcp", domain: nil), using: params)
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleResultsChanged(results, changes: changes)
            }
        }
        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed = state {
                    self?.isBrowsing = false
                }
            }
        }
        browser?.start(queue: .main)
    }
    
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        // Cancel pending resolutions
        for (_, conn) in pendingResolutions { conn.cancel() }
        pendingResolutions.removeAll()
    }
    
    private func handleResultsChanged(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        // For each .added result: extract TXT record, resolve endpoint to IP, create DiscoveredGateway
        // For each .removed result: remove from discoveredGateways
        // Deduplicate by gatewayId (gid TXT field)
        // To resolve IP: create a temporary NWConnection to the endpoint, read its resolved address
    }
}
```

**TXT record parsing**: `NWBrowser.Result` has a `.metadata` property. When the result type is `.bonjour(let record)`, the `record` is an `NWTXTRecord` which provides `getEntry(for:)` to extract `gid`, `name`, `ver`.

**IP resolution**: `NWBrowser.Result.endpoint` is an `NWEndpoint.service(...)`. To get the actual IP, create a temporary `NWConnection(to: endpoint, using: .tcp)`, wait for it to become `.ready`, read `connection.currentPath?.remoteEndpoint`, extract the host, then cancel the connection. This is a common pattern for Bonjour service resolution with Network framework.

### Task 2.2: Create `DiscoveredGatewayList` view

**New file**: `PrintParty/Features/Settings/DiscoveredGatewayList.swift`

A SwiftUI view displaying discovered gateways, designed to be embedded as a section in `AddGatewaySheet`.

```swift
import SwiftUI

struct DiscoveredGatewayList: View {
    let gateways: [GatewayBrowser.DiscoveredGateway]
    let pairedGatewayIds: Set<String>  // Already-paired gateway IDs for filtering
    let onSelect: (GatewayBrowser.DiscoveredGateway) -> Void
    let isBrowsing: Bool
    
    var body: some View {
        if isBrowsing && gateways.isEmpty {
            // Show scanning indicator
            HStack(spacing: 10) {
                ProgressView()
                Text("Scanning local network\u{2026}")
                    .foregroundStyle(.secondary)
            }
        } else if gateways.isEmpty {
            // Show "no gateways found" with help text
            Label("No gateways found on this network.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else {
            ForEach(gateways) { gw in
                let isPaired = pairedGatewayIds.contains(gw.id)
                Button {
                    if !isPaired { onSelect(gw) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gw.name).font(.body)
                            Text(gw.host).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isPaired {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "arrow.right.circle").foregroundStyle(.blue)
                        }
                    }
                }
                .disabled(isPaired)
            }
        }
    }
}
```

### Task 2.3: Integrate into `AddGatewaySheet`

**File**: `PrintParty/Features/Settings/AddGatewaySheet.swift`

**Add properties** (after line 30):
```swift
@State private var browser = GatewayBrowser()
@Query(sort: \Gateway.pairedAt) private var existingGateways: [Gateway]
```

**Compute paired IDs**:
```swift
private var pairedGatewayIds: Set<String> {
    Set(existingGateways.map(\.gatewayId).map { String($0.prefix(8)) })
}
```

**Insert discovery section** in the `Form` body (between line 47 `Form {` and line 48 the first `Section`):
```swift
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
```

**Add lifecycle** on the `NavigationStack` (after line 121 `.interactiveDismissDisabled`):
```swift
.onAppear { browser.startBrowsing() }
.onDisappear { browser.stopBrowsing() }
```

### Task 2.4: Update Info.plist

**File**: `PrintParty/Info.plist`

Add after line 23 (before the closing `</dict></plist>`):
```xml
<key>NSBonjourServices</key>
<array>
    <string>_printparty._tcp.</string>
</array>
```

Also update the `NSLocalNetworkUsageDescription` in the build settings (`project.pbxproj:418` and `:468`) to:
```
PrintParty uses your local network to discover gateways and stream print telemetry.
```

---

## Phase 3: QR Code — Gateway Side

### Task 3.1: Add QR code generation dependency

**File**: `gateway/Package.swift`

Add the `swift-qrcode-generator` package (pure Swift, MIT, no C deps):

At line 19 (in `dependencies` array):
```swift
.package(url: "https://github.com/fwcd/swift-qrcode-generator.git", from: "2.0.0"),
```

At line 28 (in target `dependencies` array):
```swift
.product(name: "QRCodeGenerator", package: "swift-qrcode-generator"),
```

### Task 3.2: Create `QRTerminalRenderer`

**New file**: `gateway/Sources/PrintPartyGateway/Discovery/QRTerminalRenderer.swift`

Generates a terminal-friendly QR code using Unicode half-block characters for correct aspect ratio.

```swift
import QRCodeGenerator

enum QRTerminalRenderer {
    
    /// Generate the QR payload URL for pairing.
    static func pairingURL(baseURL: String, code: String) -> String {
        let encodedURL = baseURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? baseURL
        return "printparty://pair?url=\(encodedURL)&code=\(code)"
    }
    
    /// Render a QR code as a terminal string using Unicode half-block characters.
    /// Uses ▀, ▄, █, and space to represent 2 rows per line (aspect ratio correction).
    static func renderToTerminal(payload: String) -> String {
        let qr = try! QRCode.encode(text: payload, ecl: .medium)
        let modules = qr.getModules()  // Bool grid
        var lines: [String] = []
        
        // Process two rows at a time using half-block characters
        let quietZone = 2
        for y in stride(from: -quietZone, to: modules.count + quietZone, by: 2) {
            var line = ""
            for x in -quietZone..<(modules.count + quietZone) {
                let top = isBlack(modules, x: x, y: y)
                let bottom = isBlack(modules, x: x, y: y + 1)
                switch (top, bottom) {
                case (true, true):   line += "█"
                case (true, false):  line += "▀"
                case (false, true):  line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
    
    private static func isBlack(_ modules: [[Bool]], x: Int, y: Int) -> Bool {
        guard y >= 0 && y < modules.count && x >= 0 && x < modules[0].count else { return false }
        return modules[y][x]
    }
}
```

### Task 3.3: Add `GET /v1/pair/qr` endpoint

**File**: `gateway/Sources/PrintPartyGateway/Routes/PairingRoutes.swift`

**Register route** at line 18 (alongside existing routes):
```swift
v1.get("pair", "qr", use: qrCode)
```

**Add handler** (after line 80, the existing `devGetCode` handler):
```swift
/// Returns the current pairing QR code. Restricted to loopback by default.
@Sendable
func qrCode(req: Request) async throws -> Response {
    // Check loopback restriction
    let allowRemote = Environment.get("QR_ALLOW_REMOTE")?.lowercased() == "true"
    if !allowRemote {
        let ip = req.remoteAddress?.ipAddress ?? ""
        guard ip == "127.0.0.1" || ip == "::1" else {
            throw Abort(.forbidden, reason: "QR endpoint restricted to localhost")
        }
    }
    
    let (code, expiresAt) = await req.pairing.currentPairingCodeWithExpiry()
    
    // Build the pairing URL using the gateway's base URL
    // Use the first resolved host from resolvePairingHosts()
    // For loopback requests, use the gateway's LAN IP, not 127.0.0.1
    let hosts = resolvePairingHosts()  // Need to make this accessible or pass via app.storage
    let baseURL = "http://\(hosts.first ?? "localhost"):\(req.application.http.server.configuration.port)"
    let payload = QRTerminalRenderer.pairingURL(baseURL: baseURL, code: code)
    
    // Content-negotiate
    if req.headers.accept.contains(where: { $0.mediaType == .json }) {
        struct QRResponse: Content {
            let payload: String
            let expiresAt: Date
        }
        return try await QRResponse(payload: payload, expiresAt: expiresAt).encodeResponse(for: req)
    }
    
    // Default: text/plain with terminal QR
    let qrArt = QRTerminalRenderer.renderToTerminal(payload: payload)
    let body = "\(qrArt)\n\nPayload: \(payload)\nExpires: \(expiresAt)\n"
    return Response(
        status: .ok,
        headers: ["Content-Type": "text/plain; charset=utf-8"],
        body: .init(string: body)
    )
}
```

**Note**: The `resolvePairingHosts()` function is currently a private function at `Configure.swift:164-177`. Either make it accessible via `Application.storage` (store the resolved hosts list during configure) or extract it into a shared utility.

### Task 3.4: Display QR in startup banner

**File**: `gateway/Sources/PrintPartyGateway/Configure.swift`

**Add env var** (alongside `BONJOUR_ENABLED`):
```swift
let qrInTerminal = Environment.get("QR_IN_TERMINAL")?.lowercased() != "false" // default true
```

**After the closing banner line** (`Configure.swift:145`, after the `╚═══` line), conditionally render the QR:
```swift
if qrInTerminal {
    let pairingURL = QRTerminalRenderer.pairingURL(
        baseURL: "http://\(pairingHosts.first ?? "localhost"):\(port)",
        code: code
    )
    let qrArt = QRTerminalRenderer.renderToTerminal(payload: pairingURL)
    app.logger.notice("\n📱 Scan to pair:\n\n\(qrArt)\n")
}
```

**Refresh on code rotation** (in the background task at `Configure.swift:116-121`): After the existing `_ = await pairingService.currentPairingCode()` call inside the loop, regenerate and log the new QR art if `qrInTerminal` is enabled.

---

## Phase 4: QR Code — iOS Side

### Task 4.1: Create `QRScannerView`

**New file**: `PrintParty/Features/Settings/QRScannerView.swift`

A SwiftUI view wrapping `AVCaptureSession` for QR code scanning.

```swift
import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onScanned: (_ url: String, _ code: String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScanned = { url, code in
            onScanned(url, code)
            dismiss()
        }
        return vc
    }
    func updateUIViewController(_ vc: QRScannerViewController, context: Context) {}
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((_ url: String, _ code: String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)
        
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
        
        captureSession = session
        Task.detached { session.startRunning() }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput results: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let result = results.first as? AVMetadataMachineReadableCodeObject,
              let string = result.stringValue else { return }
        
        // Parse printparty://pair?url=...&code=...
        guard let components = URLComponents(string: string),
              components.scheme == "printparty",
              components.host == "pair",
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return }
        
        hasScanned = true
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onScanned?(urlParam, codeParam)
    }
}
```

### Task 4.2: Register `printparty://` URL scheme and add deep-link handler

**File**: `PrintParty/Info.plist`

Add URL scheme registration:
```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>printparty</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.clengineering.PrintParty</string>
    </dict>
</array>
```

**New file**: `PrintParty/Core/DeepLinkRouter.swift`

An `@Observable` singleton that `PrintPartyApp` writes to from `.onOpenURL` and views read from:

```swift
import Foundation
import Observation

@MainActor
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()
    
    /// When set, the app should present a pairing sheet pre-filled with these values.
    var pendingPairing: (url: String, code: String)?
    
    func handle(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "printparty",
              components.host == "pair",
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return }
        
        pendingPairing = (url: urlParam, code: codeParam)
    }
    
    private init() {}
}
```

**File**: `PrintParty/PrintPartyApp.swift`

At line 41, add `.onOpenURL` to the `WindowGroup`:
```swift
WindowGroup {
    PrintersListView()
}
.modelContainer(sharedModelContainer)
.onOpenURL { url in
    DeepLinkRouter.shared.handle(url: url)
}
```

### Task 4.3: Add "Scan QR Code" button to `AddGatewaySheet`

**File**: `PrintParty/Features/Settings/AddGatewaySheet.swift`

**Add state** (after other `@State` properties):
```swift
@State private var showQRScanner = false
```

**Insert QR section** between the Connection section (ends ~line 69) and the Pairing code section (~line 71):
```swift
Section {
    Button {
        showQRScanner = true
    } label: {
        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
    }
} footer: {
    Text("Scan the QR code displayed on your gateway's terminal to fill in both fields automatically.")
        .font(.caption)
}
```

**Add scanner sheet** (after `.interactiveDismissDisabled` at line 121):
```swift
.sheet(isPresented: $showQRScanner) {
    NavigationStack {
        QRScannerView { url, code in
            baseURLString = url
            self.code = code
        }
        .navigationTitle("Scan Gateway QR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { showQRScanner = false }
            }
        }
    }
}
```

**Observe deep-link router** — in `.onAppear`, check `DeepLinkRouter.shared.pendingPairing` and pre-fill if present:
```swift
.onAppear {
    if let pending = DeepLinkRouter.shared.pendingPairing {
        baseURLString = pending.url
        code = pending.code
        DeepLinkRouter.shared.pendingPairing = nil
    }
    // ... existing onAppear logic
}
```

### Task 4.4: Add camera usage description to Info.plist

**File**: `PrintParty/Info.plist`

```xml
<key>NSCameraUsageDescription</key>
<string>PrintParty uses your camera to scan QR codes for gateway pairing.</string>
```

### Task 4.5: Update pairing error messages for QR context

**File**: `PrintParty/Core/Net/PairingClient.swift`

At line 38-44, update the `humanReason` for `invalid_or_expired_code`:
```swift
case "invalid_or_expired_code": return "Pairing code is incorrect or has expired. If using a QR code, refresh it on the gateway and scan again."
```

---

## Phase 5: Polish

### Task 5.1: Auto-pair after QR scan

In `AddGatewaySheet`, after the QR scanner fills both `baseURLString` and `code`, automatically trigger the `pair()` function if both fields are valid. Show a brief confirmation toast ("Pairing with Gateway Name...") before proceeding. Gate behind a 0.5s delay so the user sees the fields fill in.

### Task 5.2: Haptic feedback

- In `QRScannerView`: play `UIImpactFeedbackGenerator(style: .medium)` on successful scan.
- In `DiscoveredGatewayList`: play `UISelectionFeedbackGenerator` when tapping a discovered gateway.

### Task 5.3: Accessibility

- `QRScannerView`: add a `UIAccessibility.post(.announcement, "QR code scanned successfully")` notification.
- `DiscoveredGatewayList`: ensure each row has an accessibility label like "Gateway Chris's Mac at 192.168.1.42".
- Ensure the manual entry path is fully VoiceOver-compatible (it already is, but verify after UI changes).

### Task 5.4: Unit tests — QR payload parsing

**New file**: `PrintPartyKit/Tests/PrintPartyKitTests/QRPayloadTests.swift` (or in the iOS test target)

Test cases:
- Valid `printparty://pair?url=http%3A%2F%2F192.168.1.42%3A8080&code=AB3KX7YZ` parses correctly
- Missing `url` parameter returns nil
- Missing `code` parameter returns nil
- Wrong scheme (`http://pair?...`) returns nil
- URL-encoded special characters in the URL parameter decode correctly
- Code with lowercase is accepted (pairing uppercases it)

### Task 5.5: Integration test — mock `NWBrowser`

**New file**: iOS test target

Create a `MockGatewayBrowser` that conforms to the same interface as `GatewayBrowser` (extract a protocol if needed). Test that `DiscoveredGatewayList` correctly:
- Shows scanning indicator when browsing with no results
- Shows gateway list when results arrive
- Disables already-paired gateways
- Calls `onSelect` with correct data

---

## Verification Criteria

- [ ] Gateway logs "Bonjour: advertising as _printparty._tcp (port 8080)" on startup
- [ ] iOS app discovers the gateway within 3 seconds on the same LAN
- [ ] Tapping a discovered gateway fills the URL field correctly (including port)
- [ ] Already-paired gateways show a checkmark and are non-tappable
- [ ] QR code rendered in terminal is scannable by iPhone camera from 30cm distance
- [ ] `curl http://localhost:8080/v1/pair/qr` returns the QR payload (text/plain)
- [ ] `curl http://localhost:8080/v1/pair/qr -H "Accept: application/json"` returns JSON
- [ ] `curl http://<lan-ip>:8080/v1/pair/qr` returns 403 by default
- [ ] Setting `QR_ALLOW_REMOTE=true` allows the above request
- [ ] Scanning the QR code fills both URL and code fields in the iOS app
- [ ] `printparty://pair?url=...&code=...` deep link opens the app and pre-fills the pairing sheet
- [ ] Full composed flow (Bonjour discover -> QR scan -> paired) works end-to-end with zero typing
- [ ] Existing manual flow (type URL + code) continues to work unchanged
- [ ] `BONJOUR_ENABLED=false` suppresses all mDNS advertisement
- [ ] `QR_IN_TERMINAL=false` suppresses QR in the startup banner
- [ ] Camera permission denial shows a helpful alert with "Open Settings" option
- [ ] VoiceOver announces discovered gateways and QR scan results

---

## Risk Mitigations

| Risk | Mitigation |
|------|------------|
| `NWListener` port conflict with Vapor | Use port 0 for NWListener (ephemeral), advertise real port in TXT record |
| Docker can't do mDNS | `BONJOUR_ENABLED=false` env var; QR still works |
| Terminal QR unreadable | `QR_IN_TERMINAL=false` fallback + `/v1/pair/qr` HTTP endpoint |
| Camera permission denied | Detect status, show alert with "Open Settings", manual entry always works |
| URL scheme hijacking | Always show confirmation dialog with gateway name before pairing |
| Code rotates during scan | 5-min TTL is generous; error message updated with "refresh QR" guidance |
| QR payload too long for low-EC QR | Error correction M (15%) keeps data under 100 chars, well within QR capacity |
