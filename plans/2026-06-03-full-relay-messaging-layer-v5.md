# Full Relay Messaging Layer v5 — Opaque Relay with Targeted Routing

## Objective

Build a unified bidirectional WebSocket protocol where the relay is a **zero-knowledge frame forwarder** with two delivery modes: **broadcast** (events to all clients) and **peer-to-peer** (request/response to a specific client). The relay never inspects encrypted payloads — it routes solely by a plaintext prefix tag on each frame.

---

## Architecture

```
                    ┌────────────────────────────────────────┐
                    │              Relay                      │
                    │  (zero-knowledge frame router)          │
                    │                                        │
Client A ◄──WS──►  │  downstream A ◄──┐                     │
Client B ◄──WS──►  │  downstream B ◄──┼── routing by tag ◄──┤◄──WS── Gateway
Client C ◄──WS──►  │  downstream C ◄──┘                     │  (single upstream)
                    └────────────────────────────────────────┘
```

Single upstream WebSocket from gateway to relay. Multiple downstream WebSocket connections from iOS clients. The relay routes frames using a **plaintext prefix tag** — either a client UUID (peer-to-peer) or `*` (broadcast).

---

## Frame Wire Format

Every WebSocket text frame on the relay tunnel has this structure:

```
<routing-tag>:<nonce>.<ciphertext>
```

Three components separated by `:` (tag delimiter) and `.` (crypto delimiter):

| Component | Example | Who reads it |
|-----------|---------|-------------|
| `routing-tag` | `*` or `a1b2c3d4-...` | Relay only (for routing) |
| `nonce` | `kJ3xQ2m9f8a7` (base64, 16 chars) | Gateway / iOS (for decryption) |
| `ciphertext` | `p2vLmR8sT1nW...` (base64, variable) | Gateway / iOS (for decryption) |

### Routing tag semantics

| Tag | Direction | Meaning | Relay action |
|-----|-----------|---------|-------------|
| `*` | Gateway → Relay | Broadcast event | Send `<nonce>.<ciphertext>` to ALL downstream clients |
| `<clientId>` | Gateway → Relay | Response to specific client | Send `<nonce>.<ciphertext>` to that client only |
| _(none — relay prepends)_ | Client → Relay → Gateway | Client request | Relay prepends `<clientId>:` before forwarding upstream |

### Frame flow examples

**Event (broadcast): gateway pushes printer state to all clients**
```
Gateway → Relay:     "*:kJ3x.p2vL..."
Relay → Client A:    "kJ3x.p2vL..."      (stripped tag, sent to all)
Relay → Client B:    "kJ3x.p2vL..."
Relay → Client C:    "kJ3x.p2vL..."
```

**Request/Response (peer-to-peer): Client A asks for printer list**
```
Client A → Relay:    "kJ3x.q9mN..."                    (client sends encrypted frame)
Relay → Gateway:     "a1b2-...:kJ3x.q9mN..."           (relay prepends Client A's ID)
Gateway → Relay:     "a1b2-...:rT5w.yH8k..."           (gateway echoes tag in response)
Relay → Client A:    "rT5w.yH8k..."                     (relay strips tag, routes to A only)
                                                         (Clients B and C never see this frame)
```

### What the relay touches

The relay performs exactly one string operation per frame:

- **Downstream → Upstream:** prepend `<clientId>:` (the client's UUID, which the relay assigned on connect)
- **Upstream → Downstream:** split on first `:` to get the tag. If `*`, fan-out to all. Otherwise, send to the matching client.

No JSON. No decryption. No envelope parsing. The relay is a tagged message switch.

---

## Trust Model

| Entity | Sees | Cannot see |
|--------|------|-----------|
| **Relay** | Gateway IDs (URL), client UUIDs (connection tracking), routing tags (`*` vs client UUID), frame sizes, timing | Message type, method, request ID, payload content, printer data, commands, push tokens — all inside ciphertext |
| **Client B** | Nothing about Client A's requests/responses (relay doesn't send them) | — |
| **Cloudflare** | TLS-terminated frames = `tag:nonce.ciphertext` strings | Payload content |

---

## Encryption Specification

### Keys

| Key | Scope | Purpose | Created when |
|-----|-------|---------|-------------|
| **Device shared key** | Per device ↔ gateway pair | Encrypt requests (client→gw) and responses (gw→client) | LAN pairing (X25519 + HKDF) |
| **Group key** | Per gateway, all paired devices | Encrypt broadcast events (gw→all clients) | First device pairing |
| **Relay API key** | Per gateway ↔ relay | Access control for tunnel connection (not crypto) | Gateway registration |

### Encryption

- **Algorithm:** AES-256-GCM
- **Nonce:** 12 bytes, random per message
- **Plaintext:** The full `MessageEnvelope` JSON (type, id, method, deviceId, payload — everything)
- **AAD:** Empty (nothing is outside the ciphertext except the routing tag, which is relay metadata, not application data)

### Decryption on iOS

When a frame arrives on the client WebSocket:

1. The relay already stripped the routing tag, so the client receives `<nonce>.<ciphertext>`
2. Split on `.` → nonce (base64 decode → 12 bytes) + ciphertext (base64 decode)
3. **Try group key** → if success, it's a broadcast event. Decode inner JSON as `MessageEnvelope`, extract `PrintJobState` from payload.
4. **Try device shared key** → if success, it's a response to one of our requests. Decode inner JSON, match `id` to pending request continuation.
5. **Both fail** → should not happen in normal operation (relay routes correctly). Log and discard.

In practice, the client knows which key to try based on context:
- If we have pending requests, try device key first (expecting a response)
- If no pending requests, try group key first (expecting events)
- This is an optimization — trying both is fast (AES-GCM decryption failure is immediate from the auth tag check)

### On LAN (direct WebSocket, no relay)

On LAN the iOS client connects directly to the gateway at `ws://<gateway>/v1/stream?protocol=envelope`. Frames are **plaintext JSON envelopes** — no encryption, no routing tags. The encryption layer only applies to relay-tunneled connections.

```
LAN frame:  {"type":"event","method":"stream.state","payload":{...}}
Relay frame: *:kJ3x.p2vLmR8sT1nWqY4c...
```

The gateway handles both modes. The iOS `GatewayStreamClient` detects which mode based on `connectionMode` (`.lan` = plaintext envelopes, `.relay` = encrypted frames).

---

## Message Envelope (decrypted inner format)

After decryption (relay path) or directly on wire (LAN path):

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
| `type` | yes | Message kind |
| `id` | req/resp | Correlation UUID. Null for events. |
| `method` | yes | Operation name |
| `deviceId` | requests | Identifies the paired device (gateway uses this to select the shared key for encrypting the response) |
| `payload` | yes | Method-specific data |

### Method catalog

**Events (gateway → clients, broadcast with `*` tag)**

| Method | Payload | Description |
|--------|---------|-------------|
| `stream.state` | `PrintJobState` | Real-time printer state update |
| `key.rotate` | `{encryptedGroupKey, nonce}` | New group key (encrypted with device shared key — this event uses device key, tagged per-client, not `*`) |

**Request/Response (client → gateway → client, tagged per-client)**

| Method | Request Payload | Response Payload |
|--------|----------------|-----------------|
| `health` | `{}` | `{status, version, gatewayId, gatewayName, relayURL, printers}` |
| `printers.list` | `{}` | `[{id, displayName, modelName, stage, progressPercent}]` |
| `printers.state` | `{printerId}` | `PrintJobState` |
| `printers.register` | `{displayName, modelName, host, serial, accessCode}` | `{printerId, status}` |
| `printers.remove` | `{printerId}` | `{status}` |
| `activities.register` | `{printerId, pushToken, sharedKey?}` | `{status}` |
| `printer.command` | `{printerId, command: "pause"/"resume"/"cancel"}` | `{status}` |

---

## Implementation Plan

### Phase 0: Authentication + Key Provisioning

- [ ] 0.1 **Add `GatewayRegistry` to relay** — `relay/.../Registry/GatewayRegistry.swift`
  - In-memory `[String: StoredGateway]` dict with JSON file persistence at `/data/gateway-registry.json`.
  - `struct StoredGateway: Codable { let gatewayId: String; let apiKey: String; let name: String; let registeredAt: Date }`.

- [ ] 0.2 **Add `POST /v1/gateways/register` endpoint** — `relay/.../Routes/RegistrationRoutes.swift`
  - Request: `{gatewayId, gatewayName}`.
  - Generate random 32-byte hex API key.
  - Store in registry, return `{apiKey}`.
  - Rate limit: 10 per IP per hour.
  - If `gatewayId` already registered, return existing key (idempotent).

- [ ] 0.3 **Validate API key on `handleConnect`** — update `relay/.../Routes/TunnelRoutes.swift`
  - Parse `?apiKey=` from WebSocket upgrade request.
  - Look up in `GatewayRegistry`. Reject with close code 4001 if invalid.

- [ ] 0.4 **Gateway auto-registration** — update `gateway/.../Relay/RelayTunnelClient.swift`
  - New method: `register()` — calls `POST /v1/gateways/register`, stores API key at `$PRINTPARTY_DATA_DIR/relay-api-key.txt`.
  - On `start()`: if no stored API key, call `register()` first. Include key in tunnel URL: `?apiKey=<key>`.
  - On 4001 close code: re-register, retry.

- [ ] 0.5 **Rate-limit downstream connections** — update `TunnelRoutes.handleStream`
  - `TunnelBroker.downstreamCount(for:)` already exists. Check before registering: if >= 10, close with 4029.

- [ ] 0.6 **Generate group key on first pairing** — update `gateway/.../Pairing/PairingService.swift`
  - On first `completePairing()` call: generate 32 random bytes, store at `$PRINTPARTY_DATA_DIR/group-key.bin`.
  - Encrypt the group key with the device's shared key (AES-256-GCM), include in pair response as `encryptedGroupKey` + `groupKeyNonce`.

- [ ] 0.7 **Extend `PairResponse`** — update `gateway/.../Routes/PairingRoutes.swift`
  - Add `encryptedGroupKey: String?` and `groupKeyNonce: String?` fields (base64).

- [ ] 0.8 **iOS parses and stores group key** — update `PairingClient.swift` + `AddGatewaySheet.swift`
  - `PairResponse`: add `encryptedGroupKey` + `groupKeyNonce` fields.
  - `PairingResult`: add `groupKey: SymmetricKey?` (decrypted).
  - `PairingClient.pair()`: decrypt `encryptedGroupKey` using the shared key.
  - `AddGatewaySheet`: store group key in Keychain at `KeychainStore.gatewayGroupKeyAccount(gatewayId:)`.

### Phase 1: Envelope Protocol + E2EE (Gateway)

- [ ] 1.1 **Create `MessageEnvelope` model** — `gateway/.../Domain/MessageEnvelope.swift`
  - `struct MessageEnvelope: Codable` — `type: MessageType`, `id: String?`, `method: String`, `deviceId: String?`, `payload: Data` (encoded as base64 string in JSON).
  - `enum MessageType: String, Codable { case event, request, response, error }`.
  - Factory methods: `.event(method:payload:)`, `.response(id:method:payload:)`, `.error(id:method:code:message:)`.

- [ ] 1.2 **Create `FrameCrypto`** — `gateway/.../Crypto/FrameCrypto.swift`
  - `static func encryptFrame(envelope: MessageEnvelope, key: SymmetricKey) -> String`
    - JSON-encode envelope → plaintext bytes.
    - Generate 12-byte random nonce.
    - AES-256-GCM seal with key, empty AAD.
    - Return `"<base64(nonce)>.<base64(ciphertext + tag)>"`.
  - `static func decryptFrame(frame: String, key: SymmetricKey) -> MessageEnvelope?`
    - Split on `.` → nonce + ciphertext.
    - AES-256-GCM open. Decode JSON.

- [ ] 1.3 **Create `MessageRouter` actor** — `gateway/.../Messaging/MessageRouter.swift`
  - `func route(envelope: MessageEnvelope, printerService: PrinterService) async -> MessageEnvelope`
  - Dispatch by `envelope.method` to handler functions.
  - Handlers wrap existing `PrinterService` / health logic (same code as today's HTTP handlers).
  - Methods: `health`, `printers.list`, `printers.state`, `printers.register`, `printers.remove`, `activities.register`, `printer.command`.

- [ ] 1.4 **Update `StreamRoutes.handleStream`** for three client modes
  - Detect via query parameter:
    - `?protocol=encrypted` — E2EE frames (relay tunnel clients)
    - `?protocol=envelope` — plaintext JSON envelopes (LAN clients, new protocol)
    - No param — legacy raw `PrintJobState` (backward compat)
  - For encrypted/envelope clients: register `ws.onText` handler to receive and route requests.
  - Track per-client: mode, deviceId (from first request), assigned clientId (UUID).

- [ ] 1.5 **Update `PrinterService.broadcastState()`** for tagged frame output
  - Local WS clients: plaintext envelope JSON or legacy raw `PrintJobState` (per client mode).
  - Relay tunnel: encrypted frame with `*:` broadcast prefix.
    - `let frame = FrameCrypto.encryptFrame(envelope: stateEvent, key: groupKey)`
    - `tunnelClient.send(text: "*:" + frame)`

- [ ] 1.6 **Handle incoming requests from tunnel** — update `StreamRoutes` or add new tunnel request handler
  - When `RelayTunnelClient` receives a frame from the relay (client request routed upstream), it has the format `<clientId>:<nonce>.<ciphertext>`.
  - Register `ws.onText` on the tunnel upstream WS in `RelayTunnelClient`.
  - Parse: split on first `:` → clientId + encrypted frame.
  - Decrypt with the device's shared key (look up by `deviceId` inside the envelope after decryption — requires trying each paired device's key, or the `deviceId` could be sent in plaintext alongside the encrypted frame for efficiency).
  - Route to `MessageRouter`, get response envelope.
  - Encrypt response with the same device's shared key.
  - Send back: `"<clientId>:<nonce>.<ciphertext>"` — the relay routes it to that client.

- [ ] 1.7 **Device identification for request decryption**
  - Challenge: the gateway receives `<clientId>:<nonce>.<ciphertext>` from the relay. The `clientId` is a relay-assigned UUID, not the device's pairing ID. The gateway doesn't know which shared key to use until it decrypts.
  - Solution: try each paired device's shared key. With 1-5 paired devices, this is 1-5 AES-GCM attempts — microseconds. GCM auth tag failure is immediate.
  - After successful decryption, the inner `deviceId` field confirms which device. Cache the `clientId → deviceId` mapping for subsequent requests on the same connection.

### Phase 2: iOS Speaks Envelopes + E2EE

- [ ] 2.1 **Create iOS `MessageEnvelope`** — `Shared/Domain/MessageEnvelope.swift`
  - Mirror of gateway model (both Swift, same Codable format).

- [ ] 2.2 **Create iOS `FrameCrypto`** — `Shared/Crypto/FrameCrypto.swift`
  - Same encrypt/decrypt as gateway, using CryptoKit.

- [ ] 2.3 **Update `GatewayStreamClient` for dual mode**
  - LAN (`connectionMode == .lan`):
    - Connect with `?protocol=envelope`.
    - Send/receive plaintext JSON envelopes.
  - Relay (`connectionMode == .relay`):
    - Receive frames as `<nonce>.<ciphertext>` (relay already stripped the routing tag).
    - Decrypt: try group key first (events are more frequent), then device shared key (responses).
    - Send frames as `<nonce>.<ciphertext>` (relay will prepend our client ID).

- [ ] 2.4 **Add request/response API**
  - `func request(_ method: String, payload: Encodable) async throws -> Data`
  - Generate UUID `id`, build `MessageEnvelope` with type `.request`.
  - On relay: encrypt with device shared key, send encrypted frame.
  - On LAN: send plaintext envelope JSON.
  - Store `CheckedContinuation` keyed by `id`.
  - When a response/error envelope arrives with matching `id`, resume continuation with payload.
  - Timeout: 10 seconds.

- [ ] 2.5 **Update `handleMessage()` for all three frame formats**
  - Frame contains `.` and no `{` → encrypted (relay mode): decrypt, process envelope.
  - Frame starts with `{` and has `"type"` → plaintext envelope (LAN mode): decode, process.
  - Frame starts with `{` and has `"printerId"` → legacy `PrintJobState` (old gateway): decode, yield.

- [ ] 2.6 **Migrate `GatewaySyncService` to `printers.list` WS request**
  - `GatewaySyncService.syncPrinters()` calls `adapter.request("printers.list", payload: EmptyPayload())`.
  - Falls back to HTTP `GET /v1/printers` if WS request fails (backward compat with old gateways).
  - Requires threading the adapter/stream client through to `GatewaySyncService`.

- [ ] 2.7 **Migrate `LiveActivityCoordinator.forwardPushToken()` to `activities.register` WS request**
  - Same pattern: WS request with HTTP fallback.

- [ ] 2.8 **Add `GatewayAdapter.request()` pass-through**
  - `func request(_ method: String, payload: Encodable) async throws -> Data`
  - Delegates to `streamClient.request()`.

### Phase 3: Relay Goes Bidirectional

- [ ] 3.1 **Add `ws.onText` in `handleStream` (downstream handler)** — `relay/.../Routes/TunnelRoutes.swift`
  ```swift
  ws.onText { ws, text in
      // Prepend this client's ID and forward to gateway
      broker.forwardUpstream(gatewayId: gatewayId, clientId: clientId, text: text)
  }
  ```

- [ ] 3.2 **Add `TunnelBroker.forwardUpstream()`**
  - Look up upstream WS for `gatewayId`.
  - Send `"<clientId>:<text>"` — prepend the client UUID so the gateway can echo it back.

- [ ] 3.3 **Update `TunnelBroker.forward()` for tagged routing** — replace current `forward(gatewayId:text:)`
  - Receives a frame from the gateway: `"<tag>:<payload>"`
  - Split on first `:` → tag + payload.
  - If tag is `*` → send payload to all downstream clients (broadcast).
  - If tag is a client UUID → send payload to that specific client only (peer-to-peer).
  - If tag is unrecognized → log warning, drop frame.

- [ ] 3.4 **Relay still does zero crypto, zero JSON parsing**
  - The routing tag is outside the encrypted frame.
  - The relay splits on `:`, reads a UUID or `*`, and forwards the rest. That's the entire routing logic.

### Phase 4: Printer Commands

- [ ] 4.1 **Add `printer.command` handler** in gateway `MessageRouter`
  - `{printerId: UUID, command: String}` → Bambu MQTT publish:
    - `"pause"` → `{"print":{"command":"pause","sequence_id":"0"}}`
    - `"resume"` → `{"print":{"command":"resume","sequence_id":"0"}}`
    - `"cancel"` → `{"print":{"command":"stop","sequence_id":"0"}}`
  - Validates printer exists, returns `{status: "sent"}` or error.

- [ ] 4.2 **Add command UI** in iOS `PrinterDetailView`
  - Replace placeholder text at `PrinterDetailView.swift:267-282`.
  - Buttons: Pause, Resume, Cancel — shown based on current `stage`.
  - Each calls `adapter.request("printer.command", payload: CommandPayload(...))`.
  - Works identically on LAN and relay.

- [ ] 4.3 **Add `printers.register` and `printers.remove` WS methods**
  - Full remote printer management from the iOS app.
  - Existing `PrinterRoutes` logic reused in `MessageRouter` handlers.

### Phase 5: Group Key Rotation

- [ ] 5.1 **Rotate group key on device unpair** — update gateway `PairingService`
  - Generate new 32-byte group key, replace stored key.
  - For each remaining paired device: encrypt new group key with device's shared key.
  - Queue a `key.rotate` message per device (encrypted with device key, tagged with device's client ID — NOT broadcast with `*`).

- [ ] 5.2 **Send `key.rotate` on next connection** — gateway tracks pending key rotations
  - When a device's client reconnects via relay (or LAN), send the `key.rotate` envelope.
  - The device decrypts with its shared key, gets the new group key.

- [ ] 5.3 **iOS handles `key.rotate`** — update `GatewayStreamClient`
  - Detect `method: "key.rotate"` in decoded envelope.
  - Extract `encryptedGroupKey` + `nonce` from payload.
  - Decrypt with device shared key.
  - Update Keychain with new group key.
  - All subsequent event decryptions use the new key.

---

## Relay Code (complete after all phases — ~100 lines of routing logic)

```
TunnelBroker:
  upstreams:   [gatewayId: WebSocket]           // one per gateway
  downstreams: [gatewayId: [clientId: WebSocket]] // many per gateway

  registerUpstream(gatewayId, ws)    // gateway connects
  unregisterUpstream(gatewayId, ws)  // gateway disconnects → close all downstream
  registerDownstream(gatewayId, ws)  // iOS client connects → return clientId
  unregisterDownstream(gatewayId, clientId)

  forwardUpstream(gatewayId, clientId, text):
    guard let upstream = upstreams[gatewayId] else return
    upstream.send("\(clientId):\(text)")          // tag and forward

  forwardDownstream(gatewayId, text):
    let (tag, payload) = text.split(on: ":", maxSplits: 1)
    if tag == "*":
      for (_, ws) in downstreams[gatewayId]:
        ws.send(payload)                          // broadcast
    else:
      downstreams[gatewayId]?[tag]?.send(payload) // peer-to-peer
```

No crypto. No JSON. No envelopes. No request tracking. No TTLs.

---

## Security Properties

| Property | Mechanism |
|----------|-----------|
| **Payload confidentiality** | AES-256-GCM — entire envelope (type, method, id, payload) is ciphertext |
| **Payload integrity** | GCM authentication tag |
| **Device authentication** | Only paired devices hold shared key → only they can produce/consume valid frames |
| **Gateway authentication** | Only gateway holds group key → only it produces valid broadcast events |
| **Relay access control** | API key for gateway registration, rate limiting for clients |
| **Cross-client isolation** | Responses tagged per-client, encrypted with per-device key. Relay routes precisely. |
| **Relay zero-knowledge** | Sees only: gateway IDs, client UUIDs, routing tags (`*` / UUID), frame sizes, timing |
| **Device revocation** | Group key rotation on unpair — removed device can't decrypt future events |
| **Replay protection** | Random 12-byte nonce per frame, GCM rejects duplicate context |

## Metadata the relay still sees

1. Gateway IDs (URL path — necessary for routing)
2. Client UUIDs (connection tracking — necessary for routing)  
3. Routing tags: `*` (broadcast) vs specific client UUID (the relay needs this to route)
4. Frame sizes and timing (inherent to any network intermediary)
5. Connection/disconnection events

This is the minimum metadata required for a relay to function. Hiding it would require onion routing, which is disproportionate.

---

## Backward Compatibility

| Scenario | Behavior |
|----------|----------|
| **New iOS + new gateway (LAN)** | Plaintext envelopes via `?protocol=envelope`. No encryption. |
| **New iOS + new gateway (relay)** | Encrypted tagged frames. Full E2EE. |
| **Old iOS + new gateway (LAN)** | No query param → legacy raw `PrintJobState` stream + HTTP REST. |
| **New iOS + old gateway (LAN)** | Envelope handshake fails → fall back to HTTP REST + raw WS. |
| **New iOS + old gateway (relay)** | Old relay forwards raw frames → iOS detects legacy format, degrades gracefully. |

---

## Verification Criteria

- [ ] Paired iOS client on relay can list printers, register push tokens, send commands — identical to LAN.
- [ ] Unpaired device connecting to relay tunnel receives frames it cannot decrypt.
- [ ] Relay server logs contain zero plaintext application data (grep for printer names, temperatures, method names — none found).
- [ ] Client A's request/response is never delivered to Client B (verify with 2 concurrent clients + relay packet capture).
- [ ] Removing a paired device triggers group key rotation; removed device's group key fails on subsequent events.
- [ ] A compromised relay cannot forge valid frames (GCM auth tag verification fails on both gateway and iOS).
- [ ] System works through Cloudflare proxy without weakening E2EE.
- [ ] Legacy iOS clients still work with new gateway on LAN (backward compat).
- [ ] New iOS clients still work with old gateway on LAN (graceful degradation to HTTP + raw WS).
- [ ] Request/response latency through relay < 2 seconds under normal conditions.
