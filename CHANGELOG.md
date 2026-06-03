# Changelog

All notable changes to PrintParty will be recorded here. Format roughly
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); dates are
project-timeline dates, not wall-clock dates.

## [Unreleased]

### Added — Milestone 7: APNs relay + push token forwarding + E2EE

- **`printparty-relay`** (`relay/`). New Swift Package (Vapor 4 + APNSwift 5)
  producing a single stateless binary. The relay holds the APNs `.p8` auth
  key and forwards Live Activity payloads to Apple's servers on behalf of
  self-hosted gateways. It never decrypts payloads. Endpoints:
  - `GET /healthz` — liveness probe.
  - `POST /v1/push` — accepts `{deviceToken, contentState, event, timestamp}`,
    builds an `APNSLiveActivityNotification`, and calls `sendLiveActivityNotification`
    via APNSwift's HTTP/2 client. Uses an `AnyCodable` type-erased wrapper so
    any JSON content-state shape can pass through without the relay defining a
    concrete type.
  - Configurable via environment: `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
    `APNS_TOPIC`, `APNS_SANDBOX`. Starts with a placeholder config if unconfigured
    so the REST surface can be tested without a real `.p8` key.
- **Gateway push-to-relay pipeline** (`gateway/.../PrinterService.swift`).
  When the gateway broadcasts a `PrintJobState` change:
  1. It sends the state via WebSocket to connected iOS clients (as before).
  2. NEW: if any APNs push tokens are registered for that printer AND a
     `RELAY_URL` env var is set, it POSTs to `<relay>/v1/push` for each token.
  This happens in a fire-and-forget `Task` so WebSocket delivery isn't blocked.
- **`POST /v1/activities`** on the gateway. New endpoint that accepts
  `{printerId, pushToken}`. The iOS app calls this to register each
  per-activity push token it receives from ActivityKit's `pushTokenUpdates`.
- **iOS push-token forwarding** (`PrintParty/Core/LiveActivity/LiveActivityCoordinator.swift`).
  For gateway-backed printers, `Activity.request` now uses `pushType: .token`
  (instead of `nil`). The coordinator observes `activity.pushTokenUpdates`,
  hex-encodes each token, and POSTs it to the paired gateway's
  `/v1/activities` endpoint. Token observation tasks are properly canceled
  when activities end.
- **`GatewayAdapter.gatewayBaseURL`** exposed as public `let` so the
  coordinator can look up the gateway URL for push-token forwarding.
- **E2EE encryption on the gateway** (`gateway/.../Crypto/ContentStateEncryptor.swift`).
  When the iOS app forwards a push token along with its pairing-derived shared
  key (base64), the gateway stores the key per-token. On each relay push, if a
  key is available, the `PrintJobState` JSON is encrypted with ChaCha20-Poly1305
  (12-byte random nonce, combined representation = nonce + ciphertext + 16-byte
  Poly1305 tag), wrapped in an `EncryptedEnvelope` `{printerId, v, nonce, ciphertext}`,
  and forwarded as the content-state. If no key is available, plaintext is sent
  (graceful fallback for pre-E2EE setups).
- **E2EE decryption in widget extension** (`Shared/Crypto/ContentStateDecryptor.swift`).
  `ContentStateDecryptor.decrypt(envelope:sharedKeyBase64:)` reconstructs the
  `ChaChaPoly.SealedBox` from the nonce + combined data, opens it with the shared
  key, and JSON-decodes the plaintext into `PrintJobState`. Falls back gracefully
  if the content-state is not encrypted.
- **`POST /v1/activities` on the gateway** now accepts an optional `sharedKey`
  field (base64 string). The iOS app sends this alongside the push token so the
  gateway can encrypt future pushes for that device.
- **iOS `LiveActivityCoordinator.forwardPushToken`** now looks up the pairing
  shared key from Keychain and includes it in the `/v1/activities` POST body.
- **`AdapterRegistry.gatewayURLCacheSnapshot`** — new public read-only accessor
  for the gateway URL cache, used by the coordinator to resolve gatewayId for
  Keychain lookup.

### All three builds clean

- `xcodebuild -scheme PrintParty`: 0 warnings, 0 errors.
- `swift build` in `gateway/`: 0 warnings, 0 errors.
- `swift build` in `relay/`: 0 warnings, 0 errors.

### How to test the full pipeline

1. **Generate an APNs auth key** in Apple Developer portal → Certificates,
   Identifiers & Profiles → Keys → + → check "APNs" → Download the `.p8`.
2. **Start the relay:**
   ```
   cd relay
   APNS_KEY_PATH=../AuthKey_XXXXX.p8 \
   APNS_KEY_ID=XXXXXXXXXX \
   APNS_TEAM_ID=Z2Z9BCQBJN \
   APNS_TOPIC=com.clengineering.PrintParty \
   APNS_SANDBOX=true \
   swift run
   ```
3. **Start the gateway** with the relay URL:
   ```
   cd gateway
   RELAY_URL=http://localhost:8090 swift run
   ```
4. **Register a printer** on the gateway via curl (as before).
5. **Run the iOS app on a real device** (APNs doesn't work on Simulator).
6. Pair the gateway, add the printer "Via Gateway".
7. When the printer starts a job → Live Activity starts → push token is
   generated → forwarded to gateway → gateway pushes to relay → relay pushes
   to APNs → **Live Activity updates even when phone is locked / app backgrounded**.

### What works on Simulator today (no .p8 needed)

- Gateway pairing + printer registration + WebSocket stream (same as before).
- The `pushType: .token` code path compiles and the coordinator observes
  `pushTokenUpdates`, but the Simulator won't produce real APNs tokens.
  No crash, no error — just no token emitted.

### Architecture now complete

```
Printer ──MQTT──► Gateway ──WebSocket──► iOS App (foreground)
                     │
                     │ POST /v1/push
                     ▼
                  Relay ──APNs HTTP/2──► iOS Widget (background)
```

### Known limitations / next up

- E2EE encryption of the content-state is not yet implemented (plaintext
  `PrintJobState` JSON is forwarded to the relay). This is the next step
  per the v2 plan — ChaCha20-Poly1305 encryption on the gateway side,
  decryption in the widget extension.
- No HMAC gateway registration on the relay yet (any POST to /v1/push is
  accepted). Add rate-limiting + HMAC auth in a future milestone.
- Relay must be run with a real `.p8` key for pushes to actually deliver.

---

### Added — Milestone 6: Gateway Bambu adapter + WebSocket stream

- **(continued) iOS GatewayAdapter + GatewayStreamClient + Add-via-Gateway flow.**
  The iOS app can now consume printer telemetry from a paired gateway via
  WebSocket, in addition to the direct LAN path.
  - **`GatewayStreamClient`** (`PrintParty/Core/Net/GatewayStreamClient.swift`).
    `URLSessionWebSocketTask`-based client that subscribes to
    `ws://<gateway>/v1/stream`, decodes `PrintJobState` from JSON text frames,
    and yields them as an `AsyncStream`. Auto-reconnects with exponential
    backoff (2 → 4 → 8 → … → 60 seconds).
  - **`GatewayAdapter`** (`PrintParty/Core/Adapters/GatewayAdapter.swift`).
    `PrinterAdapter` implementation that wraps a `GatewayStreamClient`,
    filters for only this printer's `printerId`, and feeds the standard
    `AdapterRegistry` → `LiveActivityCoordinator` pipeline. This is the
    adapter that enables "works anywhere."
  - **`AdapterKind.gateway`** added to `Printer` model. New fields:
    `gatewayId: String?` and `remotePrinterId: UUID?` for gateway-backed
    printers. `AdapterRegistry.makeAdapter` now handles `.gateway` by
    constructing a `GatewayAdapter` pointed at the cached gateway base URL.
  - **`AdapterRegistry.cacheGatewayURL(gatewayId:baseURL:)`** — lookup cache
    populated by `PrintersListView.onAppear` from the `Gateway` SwiftData
    records, so the adapter factory can resolve `gatewayId` → `URL`.
  - **`AddGatewayPrinterSheet`**
    (`PrintParty/Features/AddGatewayPrinter/AddGatewayPrinterSheet.swift`).
    Form that lets the user pick a paired gateway, enter printer details
    (host, serial, access code), POSTs to `POST /v1/printers` on the gateway,
    and saves a local `Printer` record with `.gateway` adapter kind + the
    remote `printerId` returned by the gateway.
  - **`PrintersListView` updated**: "Add Printer" menu now shows three options:
    "Bambu A1 Mini (LAN direct)", "Via Gateway" (disabled if no gateways
    paired), and "Demo Printer (Simulated)".
  - **`PrinterDetailView`** handles `.gateway` adapter kind with a
    "Managed by gateway" info card.
- **Gateway-side Bambu MQTT adapter** (`gateway/Sources/PrintPartyGateway/`).
  The gateway now connects to Bambu printers over LAN MQTT just like the iOS
  app does. Implemented via `NIOMQTTClient` using SwiftNIO + NIOSSL (the
  gateway-compatible equivalent of the iOS `Network.framework` client).
  Includes a proper `ChannelInboundHandler` for event-driven packet receiving,
  TLS with certificate verification disabled (for Bambu's self-signed certs),
  keepalive pings, and the same `BambuTelemetryMapper` for JSON-to-`PrintJobState`
  conversion.
- **`PrinterService`** (`gateway/.../Printers/PrinterService.swift`). Actor
  that manages registered printers, runs their MQTT adapters, holds current
  `PrintJobState` per printer, and broadcasts state to all WebSocket clients.
  Handles MQTT connect/disconnect events, sends `pushall` on connect (with
  2-second retry), and reconnects with 5-second backoff on disconnect.
- **`POST /v1/printers`** — register a Bambu printer on the gateway. Accepts
  `displayName`, `modelName`, `host`, `serial`, `accessCode`. Returns the
  assigned `printerId`. The gateway immediately starts an MQTT connection.
- **`GET /v1/printers`** — list all registered printers with their current
  stage and progress.
- **`GET /v1/printers/:id/state`** — get a single printer's full
  `PrintJobState` snapshot (REST polling fallback).
- **`GET /v1/stream` (WebSocket)** — real-time `PrintJobState` stream. On
  connect, the gateway pushes the current state of all registered printers.
  As telemetry arrives, each updated `PrintJobState` is JSON-encoded and
  sent as a text frame. This is what the iOS app will subscribe to for
  live in-app updates (replacing the direct LAN adapter for gateway-paired
  printers).
- **Gateway-side domain types** (`PrintJobState`, `PrinterStage`,
  `MQTTPacket`, `BambuTelemetryMapper`). Copies of the iOS-side types
  adapted for Linux compatibility (no `Network.framework`, no `SwiftUI`).
  These will be deduplicated into a shared SPM package (`PrintPartyKit`)
  in a future milestone.

### Cleaned up

- **Zero iOS build warnings.** `xcodebuild` produces no warnings.
- **One gateway warning** from NIOSSL's `NIOSSLHandler` Sendable conformance
  (library-level; not actionable on our side).
- Fixed unused variable warning in `PrinterService`.

### Verified

- `swift build` in `gateway/` succeeds.
- `xcodebuild -scheme PrintParty` succeeds with zero warnings.

### How to test the gateway with a real printer

1. Start the gateway: `cd gateway && swift run`
2. Register your A1 Mini via curl:
   ```
   curl -X POST http://localhost:8080/v1/printers \
     -H 'Content-Type: application/json' \
     -d '{"displayName":"A1 Mini","modelName":"Bambu Lab A1 Mini","host":"192.168.1.247","serial":"YOUR_SERIAL","accessCode":"YOUR_CODE"}'
   ```
3. Subscribe to the WebSocket stream (e.g. with `websocat`):
   ```
   websocat ws://localhost:8080/v1/stream
   ```
4. You should see JSON `PrintJobState` updates flowing as the printer
   reports telemetry. Start a print on the printer — the stream should
   reflect the stage transitions and progress.

### Known limitations / next up

- The iOS app doesn't yet consume the gateway's WebSocket stream. Milestone 7
  adds `GatewayStreamClient` + `GatewayAdapter` to the iOS app so that
  gateway-registered printers drive the Live Activity instead of (or in
  addition to) the direct LAN adapter.
- Printer registrations are in-memory; they are lost when the gateway restarts.
- No authentication on the printer/stream endpoints yet (the pairing-derived
  shared key should gate access in a future milestone).

---

### Added — Milestone 5: Gateway scaffold + X25519 pairing

- **`printparty-gateway`** (`gateway/`). A new Swift Package (Vapor 4 +
  swift-crypto) producing a single `printparty-gateway` executable. Runs
  with `swift run` or as a standalone binary. Binds to `0.0.0.0:8080` by
  default (override with `HOST`/`PORT` env vars).
  - `GET /healthz` — liveness probe returning gateway identity, version, and
    current time. The iOS app calls this to verify reachability before
    attempting a pairing handshake.
  - `GET /v1/pair/code` — returns the current 8-character Base32 pairing
    code and its expiry time. Development convenience; in production the
    code is displayed in the gateway's terminal banner.
  - `POST /v1/pair` — completes the X25519 ECDH handshake. Accepts the
    device's public key + pairing code, validates the code (constant-time
    compare, single-use, 5-minute expiry), performs ECDH + HKDF-SHA256 to
    derive a 256-bit shared SymmetricKey, and responds with the gateway's
    public key. Both sides now hold the same key without it ever crossing
    the wire.
  - `PairingService` (actor) — holds the gateway's long-lived X25519
    keypair, manages code rotation, stores completed pairings in memory.
    Persistence (SQLite via Fluent) is deferred to a later milestone.
  - Friendly startup banner printed to the terminal with the pairing code,
    gateway URL, and instructions for iOS.
- **`Gateway` SwiftData model** (`PrintParty/Core/Domain/Gateway.swift`).
  Persists paired gateway identity: `gatewayId`, `displayName`, `baseURL`,
  `pairedAt`, `lastSeenAt`. The shared SymmetricKey lives in Keychain at
  `gateway.<gatewayId>.sharedKey`, not in SwiftData.
- **`PairingClient`** (`PrintParty/Core/Net/PairingClient.swift`). iOS-side
  URLSession wrapper that performs `GET /healthz` (ping) and `POST /v1/pair`
  (full handshake) against a user-hosted gateway. Generates an ephemeral
  X25519 keypair via CryptoKit, sends the public key + code, receives the
  gateway's public key, and derives the identical shared key via the same
  HKDF parameters. Returns `PairingResult` with the key.
- **Settings UI** (`PrintParty/Features/Settings/SettingsView.swift`,
  `AddGatewaySheet.swift`). Accessible via a gear icon in the printer list
  toolbar. Lists paired gateways with name, URL, and pairing timestamp.
  Swipe-to-delete wipes the gateway's Keychain entry. The "Pair Gateway"
  sheet has: URL field (defaults to `http://localhost:8080` for Simulator),
  8-char pairing code field with auto-uppercase, a "Test connection" button
  that pings `/healthz` and shows a green/red badge, and a "Pair" button
  that runs the full handshake. Error messages are surfaced inline with
  human-friendly translations for `invalid_or_expired_code`, etc.
- **`Info.plist`** (`PrintParty/Info.plist`). New file with
  `NSAppTransportSecurity / NSAllowsLocalNetworking = true` so the iOS app
  can speak cleartext HTTP to a gateway on the local network. Wired into
  the build via `INFOPLIST_FILE` in both Debug and Release configurations.
- **`KeychainStore.gatewaySharedKeyAccount(gatewayId:)`** — new naming
  convention for gateway shared keys.
- **`PrintPartyApp` schema** updated to include `Gateway.self` in the
  `ModelContainer`.
- **`PrintersListView`** now shows a gear icon (top-left) opening the
  Settings sheet.

### Project file changes

- Added `Info.plist` membership exception for the `PrintParty` synced folder
  (`PBXFileSystemSynchronizedBuildFileExceptionSet` with GUID
  `4C4AE5E02FCD600000AAE55A`).
- Added `INFOPLIST_FILE = PrintParty/Info.plist` to both Debug and Release
  build configurations for the app target.

### Verified

- `swift build` in `gateway/` succeeds. Smoke-tested `/healthz`,
  `/v1/pair/code`, and `POST /v1/pair` (wrong code → 401, bad key → 400).
- `xcodebuild -scheme PrintParty -destination 'generic/platform=iOS Simulator'`
  builds cleanly with `** BUILD SUCCEEDED **`.

### How to test end-to-end

1. In one terminal: `cd gateway && swift run`
2. Note the pairing code in the banner.
3. Run the iOS app (Simulator or device on same Wi-Fi).
4. Gear icon → Pair a Gateway → URL: `http://localhost:8080` (Simulator) or
   `http://<mac-ip>:8080` (device) → paste code → Pair.
5. The gateway should appear in the Settings list.

### Known limitations / next up

- The gateway doesn't yet run any printer adapters or push Live Activity
  updates. Milestone 6 will transplant the Bambu adapter into the gateway,
  add a WebSocket `/v1/stream` for the iOS app to subscribe to, and begin
  the APNs relay wiring.
- Pairing state is in-memory; restarting the gateway loses pairings.
  SQLite persistence is planned.
- No HTTPS on the gateway yet. `NSAllowsLocalNetworking` covers LAN use;
  a public-facing deployment would need TLS (reverse proxy or Let's Encrypt).

---

### Added — Milestone 4.2: Bambu substage detail + event-driven Live Activity

- **`PrintJobState.substageMessage: String?`** (`Shared/Domain/PrintJobState.swift`).
  Optional human-readable detail under the top-level `PrinterStage`. Vendor
  adapters can set it to disclose finer-grained activity ("Calibrating
  extrusion flow" while `stage` is `.preparing`, or "Inspecting first layer"
  while `stage` is `.printing`). Kept out of the universal `PrinterStage`
  enum so it doesn't pollute the cross-vendor model.
- **Bambu `stg_cur` parsing** (`PrintParty/Core/Bambu/BambuTelemetryMapper.swift`).
  Added the field to the decoder struct and a new `substageName(forStgCur:)`
  function that maps the 30+ known A1/P1/X1 substage codes to human strings:
  Auto bed leveling, Heatbed preheating, Heating hotend, Calibrating
  extrusion / Micro Lidar / motor noise / extrusion flow, Inspecting first
  layer, Cleaning nozzle tip, Loading/unloading filament, and every paused-
  because-X reason. Unknown codes and the 0 / 255 sentinels fall through to
  nil so the UI just shows the universal stage name.
- **Substage surfaced in UI.** `JobProgressCard` (in-app) and the Live
  Activity `LockScreenLiveActivityView` + `ExpandedTrailingView` now display
  `substageMessage` in place of the stage display name when present, so
  you'll see "Calibrating extrusion flow" instead of just "Preparing" while
  your A1 Mini is doing flow calibration at the start of a print.
- **Event-driven Live Activity updates.**
  `AdapterRegistry` (`PrintParty/Core/Adapters/AdapterRegistry.swift`) now
  calls `LiveActivityCoordinator.shared.notify(state:)` on every state
  update from any adapter, in addition to writing to its observable dict.
  `LiveActivityCoordinator.notify(state:)`
  (`PrintParty/Core/LiveActivity/LiveActivityCoordinator.swift`) is a new
  public entry point that runs the same reconcile logic per-printer.
  The 1Hz polling loop is retained as a safety net but is no longer the
  primary path — `Activity.update()` now fires as soon as telemetry arrives,
  bounded by the existing 2-second debounce that protects against APNs-style
  budget exhaustion in the future.

### Why the Live Activity wasn't updating before (clarification)

- **Foreground**: should have been working at up to 1Hz via the polled
  reconcile. The event-driven path now makes this tighter and removes any
  latency we'd previously hidden behind a tick.
- **Background / locked phone**: iOS suspends the app process, so
  `Activity.update()` from our app simply doesn't run. This is the gap that
  the gateway + APNs relay path closes (the gateway pushes updates to APNs
  while the phone is asleep, and iOS delivers them to the widget extension
  directly — no app foreground required). Nothing to do here until the
  gateway lands.

### Verified

- `xcodebuild -scheme PrintParty -destination 'generic/platform=iOS Simulator'`
  builds cleanly.

---

### Fixed — Milestone 4.1: MQTT reconnect loop

- **`MQTTClient.start(config:)` was firing a phantom `.disconnected("restart")`
  event** during its own setup by calling `stop(reason: "restart")` at the
  top. The adapter, which always reacts to disconnects by scheduling a
  reconnect, then queued a competing reconnect 2 seconds later — which killed
  the healthy connection that had just succeeded. The printer then refused
  the overlapping connection with "remote closed" and the loop restarted.
  Symptom in the unified log: every connect succeeded, then ~2 seconds later
  logged `Bambu LAN disconnected: restart` followed by `remote closed`.
  Fix: split silent `teardown()` from public `stop(reason:)`. `start()` uses
  `teardown()` (no state event); `stop()` keeps the public semantics. Also
  detach `stateUpdateHandler` before cancelling the `NWConnection` so a
  cascade callback can't re-trigger a disconnect during teardown.
- **Removed dead `connect(config:)`** method that had two contradictory
  guards and did nothing.
- **Added INFO-level telemetry log** in `BambuLanAdapter.handle(topic:payload:)`
  on stage changes (and DEBUG-level on every other update) so you can tell
  from the unified log when real telemetry is flowing.

---

### Added — Milestone 4: Real Bambu A1 Mini telemetry over LAN MQTT

- **MQTT 3.1.1 packet codec** (`PrintParty/Core/Net/MQTTPacket.swift`).
  Hand-rolled encoder/decoder covering CONNECT, CONNACK, SUBSCRIBE, SUBACK,
  PUBLISH (QoS 0), PINGREQ/PINGRESP, DISCONNECT. Variable-byte remaining-length
  encoding, UTF-8 string framing, partial-buffer-safe `tryDecode(_:)` that
  returns `(packet, bytesConsumed)` so the receive loop can drain multiple
  packets out of one TLS read.
- **`MQTTClient`** (`PrintParty/Core/Net/MQTTClient.swift`). `@MainActor`
  client built on `Network.framework` (`NWConnection` + `NWProtocolTLS`).
  Implements:
  - Custom `sec_protocol_options_set_verify_block` accepting any cert (the
    A1 Mini ships a self-signed one).
  - CONNECT with username/password (Bambu uses `bblp` + LAN access code).
  - Half-second-granularity receive loop that hops every chunk back to
    `@MainActor` and feeds `MQTTPacket.tryDecode`.
  - PINGREQ keepalive at `keepAliveSeconds / 2`; PINGRESP timeout at full
    `keepAliveSeconds` fails the connection.
  - `onStateChange` / `onMessage` callbacks instead of streams to keep
    Network.framework's queue semantics simple.
  - Uses `os.Logger` for diagnostics under `com.clengineering.PrintParty`
    subsystem.
- **`BambuTelemetryMapper`** (`PrintParty/Core/Bambu/BambuTelemetryMapper.swift`).
  Pure function that decodes a Bambu `{"print": {...}}` JSON envelope and
  merges any fields it finds into a `PrintJobState`. Handles both full
  `pushall` responses and the printer's incremental deltas (every field is
  optional). Maps `gcode_state` → `PrinterStage` (`IDLE/PREPARE/RUNNING/PAUSE/
  FINISH/FAILED`), synthesizes a `jobId` on transitions into an active stage,
  recomputes `estimatedEndAt` from `mc_remaining_time` (minutes), reads
  layer counts and four temperatures, and surfaces the first `hms` entry as
  a freeform error code/message.
- **`BambuLanAdapter` rewritten** (`PrintParty/Core/Adapters/BambuLanAdapter.swift`).
  No longer a stub. On `start()`: opens MQTT, subscribes to
  `device/<serial>/report`, publishes a `pushall` request (twice — `+0s` and
  `+2s` — to defeat lost first packets) so the printer hands us the full
  current state. On every incoming PUBLISH, runs `BambuTelemetryMapper.merge`
  and broadcasts the result. On disconnect: emits a `.offline` state with the
  disconnect reason in `errorMessage` and reconnects with exponential backoff
  (2 → 4 → 8 → 16 → 32 → 60 seconds, capped).
- **Local network usage declaration**. Added
  `INFOPLIST_KEY_NSLocalNetworkUsageDescription` to the app's Debug + Release
  configurations in `PrintParty.xcodeproj/project.pbxproj`. iOS requires this
  for connecting to LAN IPs.

### Project file changes

- One small `.pbxproj` edit to add the `NSLocalNetworkUsageDescription` key.
  No new targets, schemes, or package dependencies.

### Verified

- `xcodebuild -scheme PrintParty -destination 'generic/platform=iOS Simulator'`
  builds cleanly. Real-printer verification requires a Bambu A1 Mini in LAN-Only
  Mode on the same Wi-Fi as the simulator/device.

### Known limitations / next up

- Adapter is read-only — no pause/resume/cancel commands yet (the MQTT
  packets to send for those are well-known; will arrive in a later milestone).
- HMS error code formatting is naive; the canonical Bambu HMS code → human
  description table is not yet bundled. Today the Live Activity will show
  the raw `HMS_xxxx_xxxx_xxxx_xxxx` code if the printer reports one.
- iOS-resident LAN adapter only — phone must be on the same Wi-Fi as the
  printer for now. Milestone 5+ moves the same adapter code into the
  self-hosted gateway and adds APNs-pushed Live Activities for off-network use.

---

### Added — Milestone 3: Adapter abstraction + Bambu onboarding

- **`PrinterAdapter` protocol** (`Shared/Adapters/PrinterAdapter.swift`).
  The single contract every printer integration implements: `printerId`,
  `kind`, `stateUpdates() -> AsyncStream<PrintJobState>`, plus `start()` /
  `stop()`. `@MainActor`-isolated for now to keep concurrency simple; matches
  the v2 plan's `PrinterAdapter` boundary that will eventually live in both
  the iOS app (LAN adapters) and the user-hosted gateway (cloud adapters).
- **`MockAdapter`** (`PrintParty/Core/Adapters/MockAdapter.swift`). Wraps
  the existing demo simulation: bridges `MockPrintController.stateUpdates(for:)`
  into the `PrinterAdapter` contract. Mock printers continue to use
  `MockPrintController` directly for *demo controls* (Start / Pause / Cancel /
  Simulate Failure); the adapter just observes.
- **`BambuLanAdapter`** (`PrintParty/Core/Adapters/BambuLanAdapter.swift`).
  Skeleton implementation. Today it emits a single `PrintJobState` with
  `stage = .offline` so the rest of the system (registry, UI, Live Activity
  coordinator) can be exercised against it end-to-end. The real MQTT client
  is the only thing missing — it's wired in next milestone using
  `Network.framework` (no external SPM dependency).
- **`KeychainStore`** (`PrintParty/Core/Security/KeychainStore.swift`).
  Minimal `kSecClassGenericPassword` wrapper with `set` / `get` / `delete`
  and a canonical account name for Bambu LAN access codes
  (`bambu.<printerId>.accessCode`). `kSecAttrAccessibleWhenUnlocked`. The
  Bambu LAN access code never lives in SwiftData.
- **`AdapterRegistry`** (`PrintParty/Core/Adapters/AdapterRegistry.swift`).
  `@MainActor @Observable` runtime singleton that owns one `PrinterAdapter`
  per registered `Printer`, pumps each adapter's stream into a `[UUID:
  PrintJobState]` dict, and is now the **single source of truth** for live
  state across the UI and the Live Activity coordinator. Exposes
  `register(printer:)`, `unregister(printerId:)`, `sync(with:)`, and
  `state(for: Printer)` (returns a synthesized idle state for not-yet-emitted
  printers).
- **`Printer` SwiftData model extended** (`PrintParty/Core/Domain/Printer.swift`)
  with optional `host: String?` and `serial: String?` fields. Lightweight
  migration — existing rows simply get `nil`.
- **`AddBambuPrinterSheet`** (`PrintParty/Features/AddBambuPrinter/AddBambuPrinterSheet.swift`).
  Onboarding form with display name, host/IP, serial, and LAN access code
  (secure field with reveal toggle). Includes an inline "where to find these"
  footer pointing to the printer's settings screens. On save: writes the
  access code to Keychain *before* inserting the printer, so when SwiftData
  fires `onChange` the registry can find it.
- **`PrintersListView` revamped** (`PrintParty/Features/PrintersList/PrintersListView.swift`).
  The empty state now leads with "Add Bambu Lab A1 Mini"; the toolbar menu
  enables both adapter kinds. Calls `registry.sync(with: printers)` in
  `onAppear` and `onChange(of: printers)` to keep adapters in lockstep with
  SwiftData. Deleting a printer also wipes its Keychain entry and unregisters
  its adapter.
- **`PrinterDetailView` split controls by adapter kind**. `mockControls(...)`
  retains the demo Start/Pause/Cancel/Simulate Failure flow; `bambuControls(...)`
  shows a "stub" placeholder revealing the stored host/serial until the MQTT
  client ships.
- **`LiveActivityCoordinator` switched data source** to `AdapterRegistry`.
  Same reconcile logic and APNs-shaped debounce; now consumes the unified
  state dict instead of `MockPrintController.states`.
- **`MockPrintController.stateUpdates(for:)`** added — emits the current state
  immediately and every subsequent change to the returned `AsyncStream`. This
  is what `MockAdapter` subscribes to.

### Project file changes

- No `.pbxproj` edits this milestone (everything fits within the existing
  `PrintParty/` and `Shared/` synchronized folders).

### Verified

- `xcodebuild -scheme PrintParty -destination 'generic/platform=iOS Simulator'`
  builds cleanly. Mock printer Live Activities continue to work end-to-end.
  Bambu printers can be registered via the new form; Keychain round-trips
  the access code; the adapter reports `.offline` until Milestone 4.

### Known limitations / next up

- `BambuLanAdapter` does not yet open a network connection. Milestone 4 will
  implement the MQTT 3.1.1 client with TLS + self-signed-cert tolerance using
  `Network.framework`, subscribe to `device/<serial>/report`, and parse the
  telemetry into `PrintJobState`.

---

### Added — Milestone 2: Live Activity (server-pushed wiring deferred)

- **Shared code folder.** New `Shared/` directory synchronized to *both* the
  app target and the widget extension target via a `PBXFileSystemSynchronizedRootGroup`
  in `PrintParty.xcodeproj/project.pbxproj`. This is the canonical location
  for types that must compile in both processes.
- **Moved `PrintJobState` and `PrinterStage`** out of the app target into
  `Shared/Domain/`. They are unchanged, just relocated.
- **`PrintPartyActivityAttributes`** (`Shared/Domain/PrintPartyActivityAttributes.swift`).
  ActivityKit contract for a single tracked print. `ContentState` is currently
  `PrintJobState` directly; in a future phase it will become the encrypted
  envelope `{ printerId, v, nonce, ciphertext }` per the v2 architecture plan.
- **Widget extension reworked.** Removed the Xcode-generated `AppIntent.swift`
  and home-screen timeline widget (`PrintPartyWidgetExtension.swift`). The
  `WidgetBundle` now declares only `PrintPartyLiveActivity`.
- **`PrintPartyLiveActivity`** (`PrintPartyWidgetExtension/PrintPartyLiveActivity.swift`).
  Live Activity widget configuration covering Lock Screen banner + Dynamic
  Island (compact / minimal / expanded). Uses a `printparty://` deep-link URL.
- **`LiveActivityViews`** (`PrintPartyWidgetExtension/LiveActivityViews.swift`).
  All SwiftUI views for the Live Activity presentations:
  - Lock Screen banner with stage icon, job name, % progress, layer count,
    and a `Text(timerInterval:)` ETA countdown.
  - Dynamic Island compact (stage icon + %), minimal (progress ring),
    and expanded (printer info + temps + countdown).
  - Stage-aware tinting derived from `PrinterStage.tint`.
- **`LiveActivityCoordinator`** (`PrintParty/Core/LiveActivity/LiveActivityCoordinator.swift`).
  `@MainActor @Observable` singleton that polls `MockPrintController` at 1 Hz
  and translates state changes into `Activity.request` / `Activity.update` /
  `Activity.end` calls. Includes:
  - A 2-second rate-limit between non-stage-change updates (will become the
    APNs coalescer when we move to server pushes).
  - Immediate update on stage transitions.
  - `.after(.now + 30s)` dismissal policy on terminal states.
- **`PrintPartyApp` retains the coordinator** so the reconcile loop starts at
  app launch.

### Project file changes

- Added shared synchronized root group `Shared` (GUID `4C4AE5D02FCD500000AAE55A`)
  referenced by both `PrintParty` and `PrintPartyWidgetExtensionExtension`
  targets.
- Added `INFOPLIST_KEY_NSSupportsLiveActivities = YES` and
  `INFOPLIST_KEY_NSSupportsLiveActivitiesFrequentUpdates = YES` to the app
  target's Debug and Release configurations.

### Verified

- `xcodebuild -scheme PrintParty -destination 'generic/platform=iOS Simulator'`
  builds cleanly with `** BUILD SUCCEEDED **` for both the app and the widget
  extension.

### Known limitations / next up

- Live Activities are driven locally by `MockPrintController`; APNs push token
  registration with a gateway is not yet wired (no gateway exists yet).
- `ContentState` is plaintext `PrintJobState`. End-to-end encryption envelope
  is not yet implemented.
- No App Group entitlement is configured yet; not needed today because the
  widget consumes state from the ActivityKit content (not Keychain or shared
  defaults), but it will be required once we add the gateway pairing key store.

---

## [Milestone 1] — Foundations and mock data path

### Added

- Domain model: `PrintJobState` (the normalized snapshot every adapter
  produces) and `PrinterStage` enum (idle / preparing / printing / paused /
  finishing / done / failed / canceled / offline) with stage-aware SF Symbols
  and tint colors.
- SwiftData `Printer` model for persisting registered printers, including an
  `AdapterKind` enum (`.mock`, `.bambuLabA1Mini`).
- `MockPrintController` — a `@MainActor @Observable` singleton that simulates
  a compressed Bambu A1 Mini print:
  - 10s preparing (heat ramp on nozzle + bed)
  - 150s printing (50 layers, 0–100%)
  - 10s finishing (cooldown)
  - Pause / Resume with elapsed-time accounting
  - Cancel and "Simulate Failure" (emits HMS-style filament-runout error)
- SwiftUI app shell:
  - `PrintersListView` with empty state, add-printer menu, and swipe-to-delete.
  - `PrinterRowView` showing stage icon + live stage/% per printer.
  - `PrinterDetailView` with progress card, temperature card, stateful
    controls, and a collapsible debug raw-state panel.
  - `JobProgressCard` reusable progress card (also reused later by the widget).
- `PrintPartyApp` rewired to host `PrintersListView` and `ModelContainer` for
  `Printer`.

### Removed

- Xcode template `Item.swift` and `ContentView.swift`.

### Verified

- `xcodebuild -scheme PrintParty -destination 'generic/platform=iOS Simulator'`
  builds cleanly.
