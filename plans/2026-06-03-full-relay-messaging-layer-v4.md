# Full Relay Messaging Layer v4 — Fully Opaque Relay

## Objective

Build a unified bidirectional WebSocket protocol where the relay is a **zero-knowledge frame forwarder**. It sees only the gateway ID (from the URL) and opaque ciphertext blobs. Every byte of application data — type, method, request ID, payload — is encrypted end-to-end between the iOS client and the gateway using keys the relay never touches.

---

## Architecture

```
iOS ◄────WS────► Relay ◄────WS────► Gateway ◄──MQTT──► Printer
          │                  │
     opaque blobs       opaque blobs
     (ciphertext)       (ciphertext)
```

The relay is a **dumb pipe grouped by gateway ID**:
- Upstream frame from gateway → fan-out to all downstream clients
- Downstream frame from client → forward to the gateway's upstream WS
- No JSON parsing. No envelope inspection. No routing maps. No TTLs.

### What the relay sees per frame

```
Source:  upstream WS for gateway EF133CCD-...
Frame:   "kJ3xQ2m9f8a7bNp2vL..." (opaque base64 string)
Action:  send to all 2 downstream clients for EF133CCD-...
```

That's it. The relay has no knowledge of message types, methods, printer names, temperatures, commands, or any application semantics.

### What the endpoints decrypt

```json
{
  "type": "event",
  "id": null,
  "method": "stream.state",
  "deviceId": "device-uuid",
  "payload": { "printerId": "...", "stage": "printing", "progressPercent": 42.5, ... }
}
```

---

## Trust Model

| Entity | Sees | Can Do |
|--------|------|--------|
| **iOS client** | Everything (holds shared key + group key) | Send requests, receive events/responses, verify integrity |
| **Gateway** | Everything (holds all keys) | Process requests, send events/responses, encrypt/decrypt |
| **Relay** | Gateway IDs, connection counts, frame sizes, timing | Forward frames. Nothing else. |
| **Cloudflare** | TLS-terminated frames = ciphertext blobs | Nothing useful |
| **Network attacker** | TLS outer layer only | Nothing |

### Trust anchor

The **X25519 pairing shared key** (per-device, derived on LAN during pairing) is the root of all trust:
- Authenticates the iOS client to the gateway
- Authenticates the gateway to the iOS client
- Encrypts request/response payloads
- The **group key** (per-gateway, encrypted with each device's shared key during pairing) encrypts broadcast events

---

## Encryption Specification

### Keys

| Key | Scope | Generated When | Stored Where | Purpose |
|-----|-------|---------------|-------------|---------|
| **Device shared key** | Per gateway-device pair | LAN pairing (X25519 + HKDF) | iOS Keychain + gateway disk | Encrypt requests + responses between one device and the gateway |
| **Group key** | Per gateway (all paired devices) | First pairing | Gateway disk + iOS Keychain (encrypted transfer) | Encrypt broadcast events so all paired devices can decrypt |
| **Relay API key** | Per gateway-relay registration | Gateway's first connection to relay | Gateway disk + relay storage | Authenticate gateway's tunnel connection (not cryptographic — just access control) |

### Encryption algorithm

- **AES-256-GCM** (CryptoKit on iOS, swift-crypto on gateway)
- 12-byte random nonce per message
- AAD: empty (the entire envelope is inside the ciphertext — nothing is outside to bind)

### Frame format on the wire

Each WebSocket text frame between relay and endpoints is:

```
<base64(nonce)>.<base64(ciphertext)>
```

Two base64 strings separated by a period. That's the entire frame. The relay sees a string with a dot in the middle. It has no idea what's inside.

- `nonce`: 12 bytes (16 chars base64)
- `ciphertext`: AES-256-GCM encrypted JSON envelope (variable length)

### Decryption logic on iOS

When a frame arrives, the iOS client:
1. Split on `.` → nonce + ciphertext
2. Try decrypting with **device shared key** → if success, it's a response to one of our requests (or a per-device message)
3. If that fails, try decrypting with **group key** → if success, it's a broadcast event
4. If both fail, discard (not for us, or corrupted)

In practice, the gateway tags which key was used by convention:
- Events (broadcast): encrypted with group key
- Responses (unicast): encrypted with the requesting device's shared key

Since the relay broadcasts everything to all clients anyway, a client may receive responses to other clients' requests. Those will fail decryption with the device shared key (different device), fail with the group key (not an event), and get silently discarded. This is expected and harmless.

### On LAN: plaintext or encrypted?

On LAN (direct WS to gateway), encryption is **optional**:
- The gateway detects LAN clients via `?protocol=envelope` query parameter (plaintext envelopes) vs `?protocol=encrypted` (E2EE envelopes).
- LAN clients use plaintext for lower overhead and easier debugging.
- The gateway sends plaintext JSON envelopes to LAN clients, encrypted frames to the relay tunnel.

This means the gateway maintains two output paths:
1. **Local WS clients**: plaintext `MessageEnvelope` JSON
2. **Relay tunnel**: encrypted frames (`nonce.ciphertext`)

---

## Message Envelope (decrypted inner format)

After decryption, the plaintext JSON envelope is:

```json
{
  "type": "event" | "request" | "response" | "error",
  "id": "uuid-or-null",
  "method": "stream.state",
  "deviceId": "device-uuid",
  "payload": { ... }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `type` | yes | `event` = server push, `request` = client ask, `response` = server answer, `error` = server error |
| `id` | req/resp only | Correlation UUID. Events have `null`. |
| `method` | yes | Operation name |
| `deviceId` | requests only | Identifies which paired device sent the request (gateway uses this to look up the shared key for the response) |
| `payload` | yes | Method-specific data |

### Method catalog

| Method | Direction | Payload (request) | Payload (response) |
|--------|-----------|-------------------|-------------------|
| `stream.state` | event (gw→client) | — | `PrintJobState` |
| `health` | req/resp | `{}` | `{status, version, gatewayId, gatewayName, relayURL, printers}` |
| `printers.list` | req/resp | `{}` | `[{id, displayName, modelName, stage, progressPercent}]` |
| `printers.state` | req/resp | `{printerId}` | `PrintJobState` |
| `printers.register` | req/resp | `{displayName, modelName, host, serial, accessCode}` | `{printerId, status}` |
| `printers.remove` | req/resp | `{printerId}` | `{status}` |
| `activities.register` | req/resp | `{printerId, pushToken, sharedKey?}` | `{status}` |
| `printer.command` | req/resp | `{printerId, command}` | `{status}` |
| `key.rotate` | event (gw→client) | — | `{encryptedGroupKey}` (encrypted with device shared key, so this event uses device key, not group key) |

---

## Implementation Plan

### Phase 0: Authentication + Key Provisioning

- [ ] 0.1 **Gateway registration on relay** — `POST /v1/gateways/register`
  - Relay endpoint: accepts `{gatewayId, gatewayName}`, returns `{apiKey}`.
  - Relay stores `{gatewayId: apiKey}` in `GatewayRegistry` (in-memory + JSON file persistence at `/data/gateway-registry.json`).
  - Rate limit: 10 registrations per IP per hour.

- [ ] 0.2 **Validate API key on tunnel connect**
  - `TunnelRoutes.handleConnect`: require `?apiKey=<key>` query parameter.
  - Validate against `GatewayRegistry`. Close with 4001 (unauthorized) if invalid.

- [ ] 0.3 **Gateway auto-registration** in `RelayTunnelClient`
  - On first boot (no stored `relayApiKey`), `POST /v1/gateways/register` before opening the tunnel WS.
  - Store API key at `PRINTPARTY_DATA_DIR/relay-api-key.txt`.
  - Include in tunnel URL: `?apiKey=<key>`.
  - On 4001 rejection: re-register, get new key, retry.

- [ ] 0.4 **Rate-limit downstream connections** in `TunnelRoutes.handleStream`
  - Max 10 concurrent clients per gatewayId. Close with 4029 (too many) if exceeded.

- [ ] 0.5 **Generate group key on first pairing** — update `PairingService`
  - If no group key exists, generate 32 random bytes.
  - Store at `PRINTPARTY_DATA_DIR/group-key.bin`.
  - In `POST /v1/pair` response, add `encryptedGroupKey`: the group key encrypted with the device's shared key (AES-256-GCM, separate nonce).

- [ ] 0.6 **iOS stores group key** — update `PairingClient` + `AddGatewaySheet`
  - Parse `encryptedGroupKey` + `groupKeyNonce` from pair response.
  - Decrypt with shared key.
  - Store in Keychain at `KeychainStore.gatewayGroupKeyAccount(gatewayId:)`.

### Phase 1: Envelope Protocol + E2EE (Gateway Side)

- [ ] 1.1 **Create `MessageEnvelope` model** — `gateway/.../Domain/MessageEnvelope.swift`
  - `struct MessageEnvelope: Codable` with all fields.
  - Helpers: `.event(method:payload:)`, `.response(id:method:payload:)`, `.error(id:method:code:message:)`.

- [ ] 1.2 **Create `FrameCrypto` utility** — `gateway/.../Crypto/FrameCrypto.swift`
  - `static func encrypt(envelope: MessageEnvelope, key: SymmetricKey) -> String` → returns `"<nonce>.<ciphertext>"` string.
  - `static func decrypt(frame: String, key: SymmetricKey) -> MessageEnvelope?` → splits on `.`, decrypts, decodes JSON.

- [ ] 1.3 **Create `MessageRouter` actor** — `gateway/.../Messaging/MessageRouter.swift`
  - Method dispatch map: `[String: (Data) async throws -> Data]`.
  - Handlers wrap existing `PrinterService` methods.
  - Methods: `health`, `printers.list`, `printers.state`, `printers.register`, `printers.remove`, `activities.register`, `printer.command`.

- [ ] 1.4 **Update `StreamRoutes.handleStream`** for dual-mode clients
  - `?protocol=encrypted` → E2EE mode (encrypted frames, request/response support)
  - `?protocol=envelope` → plaintext envelope mode (for LAN debugging)
  - No query param → legacy raw `PrintJobState` mode (backward compat)
  - Register `ws.onText` for encrypted/envelope clients to handle incoming requests.

- [ ] 1.5 **Update `PrinterService.broadcastState()`** for dual output
  - Local WS clients: plaintext `MessageEnvelope` JSON or legacy raw `PrintJobState` (per client mode).
  - Relay tunnel: encrypted frame string using group key.

- [ ] 1.6 **Update `RelayTunnelClient.send(text:)`** to send encrypted frames
  - `broadcastState()` passes an already-encrypted frame string to the tunnel client.

### Phase 2: iOS Speaks Envelopes + E2EE

- [ ] 2.1 **Create iOS `MessageEnvelope`** — `Shared/Domain/MessageEnvelope.swift`

- [ ] 2.2 **Create iOS `FrameCrypto`** — `Shared/Crypto/FrameCrypto.swift`
  - Same encrypt/decrypt as gateway.

- [ ] 2.3 **Update `GatewayStreamClient` for envelope/encrypted modes**
  - On LAN: connect with `?protocol=envelope`, send/receive plaintext envelopes.
  - On relay: receive encrypted frames, decrypt with group key (events) or device shared key (responses).
  - Send encrypted frames when making requests through relay.

- [ ] 2.4 **Add request/response API to `GatewayStreamClient`**
  - `func request(_ method: String, payload: Encodable) async throws -> Data`
  - Pending requests map: `[String: CheckedContinuation<Data, Error>]`
  - Encrypts with device shared key when on relay.
  - 10-second timeout.

- [ ] 2.5 **Decryption logic in `handleMessage()`**
  - If frame contains `.` → encrypted mode:
    1. Try device shared key → response to our request
    2. Try group key → broadcast event
    3. Both fail → discard (response to another client)
  - If frame is valid JSON → plaintext envelope (LAN mode)
  - If frame is valid `PrintJobState` JSON → legacy mode

- [ ] 2.6 **Migrate `GatewaySyncService` to WS `printers.list` request**
  - HTTP fallback for old gateways that don't support envelopes.

- [ ] 2.7 **Migrate `LiveActivityCoordinator.forwardPushToken()` to WS `activities.register` request**
  - HTTP fallback.

- [ ] 2.8 **Add `GatewayAdapter.request()` pass-through**

### Phase 3: Relay Goes Bidirectional

- [ ] 3.1 **Add `ws.onText` in `TunnelRoutes.handleStream`** (downstream handler)
  - Forward client frames to the upstream gateway WebSocket.
  - The relay treats the frame as an opaque string — no parsing.
  ```swift
  ws.onText { ws, text in
      broker.forwardUpstream(gatewayId: gatewayId, text: text)
  }
  ```

- [ ] 3.2 **Add `TunnelBroker.forwardUpstream()`**
  - Look up the upstream WS for the given gatewayId.
  - Send the opaque frame. Done.

- [ ] 3.3 **No routing logic needed**
  - Gateway responses go through the existing fan-out path (upstream → all downstream).
  - Each iOS client decrypts with its device key. Only the intended recipient succeeds.
  - Other clients' decryption fails silently → frame discarded.
  - Zero additional relay complexity.

### Phase 4: Printer Commands

- [ ] 4.1 **Add `printer.command` handler** in gateway `MessageRouter`
  - `{printerId, command: "pause" | "resume" | "cancel"}`
  - Maps to Bambu MQTT publish on `device/<serial>/request`.

- [ ] 4.2 **Add command UI** in iOS `PrinterDetailView`
  - Replace placeholder controls with real Pause/Resume/Cancel buttons.
  - Calls `adapter.request("printer.command", payload: ...)`.
  - Works identically on LAN and relay.

- [ ] 4.3 **Add `printers.register` and `printers.remove` WS methods**
  - Full remote printer management from the iOS app.

### Phase 5: Group Key Rotation

- [ ] 5.1 **Rotate group key when a device is unpaired**
  - Gateway generates new 32-byte group key.
  - For each remaining paired device: encrypt new group key with that device's shared key.
  - Send `key.rotate` event to each device (encrypted with device key, NOT group key — since the old group key is compromised).

- [ ] 5.2 **iOS handles `key.rotate`**
  - Decrypt new group key with device shared key.
  - Update Keychain.
  - Future events use the new group key.

---

## Relay Implementation (complete — it's this simple)

After all phases, the relay's `TunnelBroker` does exactly three things:

```
1. Gateway connects    → store upstream WS, keyed by gatewayId
2. Client connects     → store downstream WS, keyed by gatewayId + clientId  
3. Forward frames:
   - Upstream text frame  → send to all downstream clients (fan-out)
   - Downstream text frame → send to upstream gateway (forward)
```

No JSON parsing. No envelope inspection. No request-ID maps. No TTLs. No crypto. The relay is ~150 lines of code and completely stateless beyond connection tracking.

---

## Security Properties

| Property | How | What breaks if violated |
|----------|-----|----------------------|
| **Confidentiality** | AES-256-GCM on entire envelope | Relay/attacker can read printer data |
| **Integrity** | GCM auth tag covers entire envelope | Attacker can forge state updates or commands |
| **Device authentication** | Only paired devices hold shared key → only they can decrypt responses | Unpaired device receives ciphertext it can't use |
| **Gateway authentication** | Only the gateway holds the group key → only it can produce valid encrypted events | Fake gateway's events fail decryption on iOS |
| **Relay access control** | API key for gateway registration | Random processes can't impersonate gateways |
| **Abuse prevention** | Rate limiting (10 clients/gateway, 10 registrations/IP/hour) | DoS via connection flooding |
| **Replay protection** | Random 12-byte nonce per message | Replayed frames produce duplicate nonces, GCM context collision detectable |
| **Cross-client isolation** | Responses encrypted with per-device key | Client A can't decrypt Client B's responses |
| **Device revocation** | Group key rotation on unpair | Removed device can't decrypt future events |

## What the relay sees (exhaustive list)

1. Gateway IDs (from URL path)
2. Number of connected clients per gateway
3. Frame sizes and timing
4. Relay API keys (for access control, not crypto)
5. Client IP addresses

It does **not** see: message types, methods, request IDs, printer names, temperatures, progress, job names, commands, push tokens, or any application data whatsoever.

---

## Backward Compatibility

| Scenario | Behavior |
|----------|----------|
| New iOS + new gateway (LAN) | Plaintext envelopes via `?protocol=envelope` |
| New iOS + new gateway (relay) | Encrypted frames via relay tunnel |
| Old iOS + new gateway (LAN) | Legacy raw `PrintJobState` stream + HTTP REST (no query param detected) |
| New iOS + old gateway (LAN) | iOS falls back to HTTP REST + raw WS when envelope handshake fails |
| New iOS + old gateway (relay) | Old relay only forwards raw `PrintJobState` — iOS receives legacy frames through tunnel |
