# Auto-Discovery and QR Code Pairing for PrintParty

## Objective

Eliminate manual data entry during gateway pairing. Today users must type a URL like `http://192.168.1.42:8080` and an 8-character code into the iOS app. This plan introduces two complementary features:

1. **Bonjour/mDNS auto-discovery** — the gateway advertises itself on the LAN; the iOS app finds it automatically (user still enters the pairing code).
2. **QR code pairing** — the gateway displays a QR code containing both URL and code; the iOS app scans it and pairs with zero typing.

When composed: the app discovers gateways via Bonjour, the user taps one, then scans the QR code displayed on the gateway's terminal/web UI to complete pairing instantly.

---

## Current Architecture (Reference)

| Component | File | Role |
|-----------|------|------|
| Gateway startup + banner | `gateway/Sources/PrintPartyGateway/Configure.swift:14-147` | Binds to `0.0.0.0:8080`, prints pairing URLs + code to console |
| Health endpoint | `gateway/Sources/PrintPartyGateway/Routes/HealthRoutes.swift` | `GET /healthz` returns `gatewayId`, `gatewayName`, `version` |
| Pairing endpoint | `gateway/Sources/PrintPartyGateway/Routes/PairingRoutes.swift` | `POST /v1/pair` with X25519 ECDH handshake, rate-limited |
| Pairing code generation | `gateway/Sources/PrintPartyGateway/Pairing/PairingService.swift:240-245` | 5 random bytes -> Base32 -> 8 chars, rotates every 5 min |
| iOS pairing UI | `PrintParty/Features/Settings/AddGatewaySheet.swift` | Manual text fields for URL + code, "Test connection" button |
| iOS pairing client | `PrintParty/Core/Net/PairingClient.swift` | `ping()` calls `/healthz`, `pair()` does the ECDH handshake |
| Shared types | `PrintPartyKit/Sources/PrintPartyKit/` | `MessageEnvelope`, `PrintJobState`, `FrameCrypto` |
| Gateway Package.swift | `gateway/Package.swift` | Vapor 4.92+, swift-crypto 3.0+, local PrintPartyKit |

Key constraints:
- Gateway runs on macOS (Mac/NAS/VPS); also works in Docker (`docker-compose.yml` present).
- Pairing codes are single-use and expire after 5 minutes (`PairingService.swift:59`).
- After pairing, the shared key is stored in iOS Keychain and a `Gateway` SwiftData record is inserted.
- The iOS app uses `AdapterRegistry` to open a WebSocket immediately after pairing.

---

## Approach 1: Bonjour/mDNS Auto-Discovery

### Data Format

**Service type**: `_printparty._tcp.`  
**Domain**: `local.`  
**Port**: The gateway's HTTP port (default 8080)  

**TXT record fields** (RFC 6763 key=value pairs, each value < 255 bytes):

| Key | Value | Example |
|-----|-------|---------|
| `gid` | Gateway UUID (truncated to first 8 chars for brevity) | `a3f7c2e1` |
| `name` | Gateway display name (UTF-8, max 63 bytes) | `Chris's Mac` |
| `ver` | Gateway version | `0.1.0` |
| `path` | API base path (for future reverse-proxy support) | `/` |

The TXT record does **not** include the pairing code — that remains a secret the user must read from the terminal or QR code.

### Gateway Changes

- [ ] **1. Add `BonjourAdvertiser` actor** — new file `gateway/Sources/PrintPartyGateway/Discovery/BonjourAdvertiser.swift`. Uses `NetService` (Foundation) to publish a `_printparty._tcp` service on the gateway's listen port. Constructs the TXT record dictionary from the gateway's identity. Implements `NetServiceDelegate` to log publish success/failure. Provides `start()` and `stop()` methods.

- [ ] **2. Wire `BonjourAdvertiser` into `Configure.swift`** — after route registration (~line 106), create a `BonjourAdvertiser` with the gateway's `gatewayId`, `gatewayName`, version, and bound port. Call `start()`. Store it in `Application.storage` so it lives as long as the server. Add `stop()` to `GatewayLifecycleHandler.shutdown()` for clean de-advertisement on quit.

- [ ] **3. Add `BONJOUR_ENABLED` environment variable** — default `true`. When set to `false`, skip Bonjour advertisement entirely. This is important for Docker/VPS deployments where mDNS is unavailable or unwanted. Document in the startup banner.

- [ ] **4. Update startup banner** — add a line like `Bonjour: advertising as _printparty._tcp (port 8080)` when enabled, or `Bonjour: disabled` when not. This goes in `Configure.swift` around line 131-146.

### iOS App Changes

- [ ] **5. Create `GatewayBrowser` ObservableObject** — new file `PrintParty/Core/Net/GatewayBrowser.swift`. Uses `NWBrowser` (Network framework) to browse for `_printparty._tcp` services. Publishes a `@Published var discoveredGateways: [DiscoveredGateway]` array. Each `DiscoveredGateway` holds: `name`, `host`, `port`, `gatewayId`, `txtRecord`. Handles service resolution via `NWConnection` endpoint to extract the IP address. Provides `startBrowsing()` and `stopBrowsing()` methods. Deduplicates by `gatewayId` and removes stale entries when services disappear.

- [ ] **6. Add `DiscoveredGatewayList` view** — new file `PrintParty/Features/Settings/DiscoveredGatewayList.swift`. A SwiftUI `List` that displays all discovered gateways with their name, IP, and a signal-strength indicator. Shown as a section in the updated `AddGatewaySheet`. Tapping a gateway auto-fills the URL field. Shows a "Scanning local network..." indicator while browsing. Displays "No gateways found" with a help tip after 5 seconds if the list is empty.

- [ ] **7. Update `AddGatewaySheet.swift`** — add a `@StateObject private var browser = GatewayBrowser()` property. Insert a new `Section` at the top of the `Form` (above the current "Connection" section) with `DiscoveredGatewayList`. When a user taps a discovered gateway, populate `baseURLString` with the resolved `http://host:port`. Start browsing in `.onAppear`, stop in `.onDisappear`. The manual URL field remains as a fallback for remote/VPS gateways.

- [ ] **8. Filter already-paired gateways** — cross-reference `discoveredGateways` against existing `Gateway` SwiftData records by `gatewayId`. Show already-paired ones with a checkmark and disable tap, so users don't accidentally re-pair.

- [ ] **9. Add `NSLocalNetworkUsageDescription` and Bonjour service entry to Info.plist** — iOS requires a privacy description for local network access, and the specific Bonjour service type must be declared in `NSBonjourServices` as `_printparty._tcp.` for `NWBrowser` to function.

### Security Considerations

- Bonjour advertisement is **LAN-only** and reveals the gateway's existence, name, and ID to anyone on the same network segment. This is acceptable because the pairing code is still required and rate-limited (10 attempts/60s per IP).
- The TXT record must **never** include the pairing code, shared keys, or any secret material.
- On untrusted networks (coffee shops, hotels), Bonjour advertisement could be disabled via the env var. The startup banner should include a note about this.

---

## Approach 2: QR Code Pairing

### QR Code Payload Format

A URL with a custom scheme carrying the base URL and pairing code:

```
printparty://pair?url=http%3A%2F%2F192.168.1.42%3A8080&code=AB3KX7YZ
```

| Component | Value |
|-----------|-------|
| Scheme | `printparty` |
| Host | `pair` |
| Query `url` | The gateway's base URL, percent-encoded |
| Query `code` | The current 8-character pairing code |

**Why a custom URL scheme instead of raw JSON?**
- iOS can register `printparty://` as a universal link, enabling future NFC/tap-to-pair.
- URL-based payloads are shorter and more tolerant of QR scanner apps.
- The URL structure is extensible (add `relay=` param later for remote pairing).

**QR error correction level**: M (15%) — balances data density with readability on terminal backgrounds.

### Gateway Changes

- [ ] **10. Add `QRCodeGenerator` utility** — new file `gateway/Sources/PrintPartyGateway/Discovery/QRCodeGenerator.swift`. A pure-Swift QR code generator that outputs a UTF-8 block-character string (using `█`, `░`, or Unicode block elements) suitable for terminal display. Accepts a string payload and returns the rendered QR. Consider using a lightweight dependency like `swift-qrcode-generator` (MIT, no external C deps) or embedding QR generation directly — the encoding is well-specified and only ~300 lines for basic support. Evaluate both options.

- [ ] **11. Add `GET /v1/pair/qr` endpoint** — new route in `PairingRoutes.swift`. Returns the QR code in two formats based on `Accept` header:
  - `text/plain` (default): UTF-8 terminal-friendly QR block art, suitable for `curl` or SSH.
  - `image/png`: A PNG image of the QR code (for the web UI, if added later).
  - `application/json`: Returns `{ "payload": "printparty://pair?...", "expiresAt": "..." }` for programmatic use.
  The endpoint should be **localhost-only or require a local connection** (see security below). Regenerates when the pairing code rotates.

- [ ] **12. Display QR in startup banner** — after the existing banner text in `Configure.swift:131-146`, render the QR code below it using terminal block characters. Gate this behind a `QR_IN_TERMINAL` env var (default `true`) since some terminals (e.g., Docker logs, remote syslog) don't render Unicode blocks well. The QR should refresh when the code rotates — log the new QR at NOTICE level alongside the new code.

- [ ] **13. Rate-limit `/v1/pair/qr`** — reuse the existing `PairingRateLimiter` or add a simpler one. Although this endpoint doesn't perform pairing, it exposes the current pairing code. Restrict it to loopback addresses (`127.0.0.1`, `::1`) by default, with an env var `QR_ALLOW_REMOTE=true` to enable it on all interfaces (for headless/web UI setups).

### iOS App Changes

- [ ] **14. Create `QRScannerView`** — new file `PrintParty/Features/Settings/QRScannerView.swift`. A SwiftUI view wrapping `AVCaptureSession` with a `AVCaptureMetadataOutput` delegate filtered to `.qr` type. Uses a `UIViewRepresentable` or `UIViewControllerRepresentable` bridge. Parses the scanned string, validates it matches the `printparty://pair?url=...&code=...` format, and calls a completion handler with the extracted URL and code. Includes a viewfinder overlay and a torch toggle button.

- [ ] **15. Register `printparty://` URL scheme** — add to the Xcode project's URL Types in Info.plist. Also add `CFBundleURLSchemes` entry. This enables deep-linking if the QR is scanned by the system Camera app or a third-party scanner — the app opens and begins pairing automatically.

- [ ] **16. Add deep-link handler** — in the app's `@main` struct or `SceneDelegate`, handle `printparty://pair?url=...&code=...` URLs. Parse the URL, validate parameters, and present the `AddGatewaySheet` pre-filled with the URL and code. If the app is already showing the sheet, update its fields.

- [ ] **17. Add "Scan QR Code" button to `AddGatewaySheet`** — insert a prominent button (or a new `Section`) in the form, above the manual fields. Tapping it presents `QRScannerView` as a sheet. On successful scan, dismiss the scanner, populate both `baseURLString` and `code`, and optionally auto-trigger pairing (with a brief confirmation). This makes the flow: tap "+", tap "Scan QR", point at terminal -> paired.

- [ ] **18. Add `NSCameraUsageDescription` to Info.plist** — required for camera access. Text: "PrintParty uses your camera to scan QR codes for gateway pairing."

- [ ] **19. Handle QR code expiry gracefully** — since QR codes embed a pairing code that expires in 5 minutes, the `PairingError.server` case for `invalid_or_expired_code` should suggest the user "refresh the QR code on the gateway and try again." Update the error mapping in `PairingClient.swift:38-44`.

### Security Considerations

- The QR code contains the pairing code in plaintext. Anyone who can see the terminal or photograph the screen can pair. This is acceptable because:
  - The code is single-use (consumed on first successful pairing).
  - The code expires in 5 minutes.
  - The pairing endpoint is rate-limited (10 attempts/60s).
- The `/v1/pair/qr` HTTP endpoint is more concerning — it returns the live code over the network. Restricting to loopback by default prevents LAN attackers from harvesting codes. The env var escape hatch is for legitimate headless setups.
- The `printparty://` URL scheme is not globally unique. A malicious app could register the same scheme. Mitigation: always show a confirmation dialog with the gateway name (from `/healthz`) before completing pairing. Never auto-pair silently from a deep link.

---

## Composed Flow: Bonjour + QR Together

The optimal user experience combines both approaches:

```
1. User opens iOS app → Settings → Gateways → "+"
2. App starts Bonjour browsing
3. Gateway appears in "Nearby Gateways" list within 1-2 seconds
4. User taps gateway → URL field auto-fills
5. User taps "Scan QR Code" → camera opens
6. User points phone at gateway's terminal QR code
7. Code field auto-fills → pairing triggers automatically
8. Done. Zero typing.
```

Fallback paths remain fully functional:
- **No Bonjour** (VPS/Docker): User types the URL manually, scans QR for the code.
- **No camera** (Simulator, accessibility): User types both URL and code manually (current flow).
- **No QR** (SSH-only access): User discovers via Bonjour, types the code from terminal output.

---

## Implementation Plan (Ordered)

### Phase 1: Bonjour Discovery (Gateway)
- [ ] 1. Create `BonjourAdvertiser` actor with `NetService` (`Discovery/BonjourAdvertiser.swift`)
- [ ] 2. Wire into `Configure.swift` startup and `GatewayLifecycleHandler` shutdown
- [ ] 3. Add `BONJOUR_ENABLED` env var, update startup banner

### Phase 2: Bonjour Discovery (iOS)
- [ ] 4. Create `GatewayBrowser` ObservableObject with `NWBrowser` (`Core/Net/GatewayBrowser.swift`)
- [ ] 5. Create `DiscoveredGatewayList` view (`Features/Settings/DiscoveredGatewayList.swift`)
- [ ] 6. Integrate into `AddGatewaySheet` — add browser section, auto-fill on tap
- [ ] 7. Add Info.plist entries (`NSLocalNetworkUsageDescription`, `NSBonjourServices`)
- [ ] 8. Filter already-paired gateways by `gatewayId`

### Phase 3: QR Code (Gateway)
- [ ] 9. Evaluate and add QR generation capability (dependency or embedded)
- [ ] 10. Create `QRCodeGenerator` utility for terminal rendering
- [ ] 11. Add `GET /v1/pair/qr` endpoint with loopback restriction
- [ ] 12. Display QR in startup banner, refresh on code rotation

### Phase 4: QR Code (iOS)
- [ ] 13. Create `QRScannerView` with `AVCaptureSession` + viewfinder overlay
- [ ] 14. Register `printparty://` URL scheme, add deep-link handler
- [ ] 15. Add "Scan QR Code" button to `AddGatewaySheet`
- [ ] 16. Add `NSCameraUsageDescription` to Info.plist
- [ ] 17. Update `PairingError` messages for QR-specific guidance

### Phase 5: Polish
- [ ] 18. Auto-pair flow: scan QR -> confirm gateway name -> pair (single tap after scan)
- [ ] 19. Haptic feedback on successful QR scan and Bonjour discovery
- [ ] 20. Accessibility: VoiceOver announcements for discovered gateways and scan results
- [ ] 21. Unit tests for QR payload parsing (URL scheme validation, edge cases)
- [ ] 22. Integration test: mock `NWBrowser` results in `GatewayBrowser` tests

---

## Verification Criteria

- Gateway logs "Bonjour: advertising as _printparty._tcp (port 8080)" on startup
- iOS app discovers the gateway within 3 seconds on the same LAN
- Tapping a discovered gateway fills the URL field correctly (including port)
- QR code rendered in terminal is scannable by iPhone camera from 30cm distance
- `curl http://localhost:8080/v1/pair/qr` returns the QR payload
- `curl http://<lan-ip>:8080/v1/pair/qr` returns 403 by default
- Scanning the QR code fills both URL and code fields in the iOS app
- `printparty://pair?url=...&code=...` deep link opens the app and pre-fills the pairing sheet
- Full composed flow (Bonjour discover -> QR scan -> paired) works end-to-end with zero typing
- Existing manual flow (type URL + code) continues to work unchanged
- Setting `BONJOUR_ENABLED=false` suppresses all mDNS advertisement
- Setting `QR_IN_TERMINAL=false` suppresses QR in the startup banner

---

## Potential Risks and Mitigations

1. **`NetService` is deprecated on macOS 13+**  
   Mitigation: Use `NWListener` with `NWListener.Service` (Network framework) instead if targeting macOS 14+. The gateway's `Package.swift` already specifies `.macOS(.v14)`, so `NWListener` is available. `NWBrowser` on iOS is the modern equivalent and is already the recommended approach for the iOS side.

2. **Docker containers cannot do mDNS**  
   Mitigation: The `BONJOUR_ENABLED=false` env var disables advertisement. Document in `docker-compose.yml` that `network_mode: host` is required for Bonjour. QR code pairing still works in Docker since it only needs HTTP.

3. **Terminal QR rendering quality varies**  
   Mitigation: Use Unicode half-block characters (`▀`, `▄`, `█`, ` `) for 2:1 aspect ratio correction — this produces scannable codes in most modern terminals (iTerm2, Terminal.app, VS Code integrated terminal). The `QR_IN_TERMINAL=false` env var provides an escape hatch. The HTTP endpoint (`/v1/pair/qr`) serves as an alternative.

4. **Camera permission denied on iOS**  
   Mitigation: Detect `AVCaptureDevice.authorizationStatus` before presenting the scanner. If denied, show an alert with a "Open Settings" button. The manual code entry path remains fully functional.

5. **QR code scanned by wrong app / malicious URL scheme hijacking**  
   Mitigation: Always show a confirmation dialog displaying the gateway name (fetched from `/healthz`) before completing pairing. Never auto-pair silently from a deep link without user confirmation.

6. **Race condition: code rotates between QR display and scan**  
   Mitigation: The 5-minute TTL is generous for a scan that takes seconds. If it does expire, the error message (updated in task 19) clearly tells the user to refresh. No architectural change needed.

---

## Alternative Approaches

1. **mDNS-SD via `dns-sd` CLI wrapper** instead of Network framework: Simpler but less robust, no delegate callbacks, harder to manage lifecycle. Not recommended.

2. **Embed pairing code in Bonjour TXT record**: Eliminates QR entirely — tap a discovered gateway and pair with zero interaction. Rejected because the TXT record is visible to all LAN devices, effectively making the pairing code public on the network. Any device on the LAN could auto-pair without physical proximity.

3. **WebSocket-based proximity pairing**: Gateway broadcasts an encrypted challenge over WebSocket; only devices that can prove physical proximity (via Bluetooth LE or ultrasonic) can pair. More secure but dramatically more complex and not needed for the home-network threat model.

4. **Universal Links instead of custom URL scheme**: Would require a registered domain and AASA file. Overkill for a self-hosted tool, and the gateway has no guaranteed public domain. Custom scheme is sufficient.
