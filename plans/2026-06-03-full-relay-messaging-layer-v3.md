# Full Relay Messaging Layer — Secure Public Relay from Day One

## Objective

Build a unified bidirectional WebSocket protocol with **authentication and E2EE baked in from the start**, so the relay is safe for public multi-user hosting from day one — not retrofitted later. Every user's gateway-to-iOS communication is end-to-end encrypted, and the relay is a zero-knowledge forwarder that can't read, modify, or forge any user data.

---

## Trust Model

### Principals

| Entity | Trust Level | What It Knows |
|--------|------------|---------------|
| **iOS client** | Fully trusted | Shared key from pairing, gateway identity |
| **Gateway** | Fully trusted | Shared key from pairing, printer credentials, all telemetry |
| **Relay** | **Untrusted** | Only routing metadata (gateway ID, client ID, message type). Cannot read payloads. Cannot forge messages. |
| **Cloudflare** | **Untrusted** | Sees TLS-terminated traffic, but payloads are E2EE ciphertext |
| **Network attacker** | **Untrusted** | Sees TLS outer layer only. Inner payloads are E2EE. |

### Trust Anchor

The **X25519 pairing shared key** (derived during LAN pairing) is the root of trust. Everything flows from it:
- It authenticates the iOS client to the gateway (proof of pairing)
- It authenticates the gateway to the iOS client (proof of identity)
- It encrypts all payloads (confidentiality)
- It MACs all messages (integrity)

The relay never sees this key. The relay is a dumb pipe.

---

## Authentication Design

### Problem: Who is allowed to connect?

Three connections need authentication:
1. **Gateway → Relay** (upstream tunnel): prove this gateway is registered
2. **iOS → Relay** (downstream tunnel): prove this client is paired with a specific gateway
3. **iOS ↔ Gateway** (through relay): prove both ends hold the shared pairing key

### Solution: Two-layer authentication

**Layer 1 — Relay Registration (gateway ↔ relay)**

The gateway registers with the relay on first boot, receiving a **relay API key**. This key authenticates the gateway's tunnel connection so random processes can't impersonate gateways.

- Gateway calls `POST /v1/gateways/register` on the relay with `{gatewayId, gatewayName}`.
- Relay generates a random API key, stores `{gatewayId, apiKey, registeredAt}` in memory (or a lightweight store).
- Relay returns `{apiKey}`.
- Gateway stores the API key on disk alongside its identity.
- All subsequent tunnel connections include the API key: `/v1/tunnel/<gatewayId>/connect?apiKey=<key>`.
- Relay validates the API key before accepting the WebSocket upgrade.

This prevents impersonation of gateways on the relay. The API key is relay-specific and has no relationship to pairing keys.

**Layer 2 — Client Ticket (iOS ↔ gateway, issued over LAN)**

When an iOS client pairs with a gateway, the gateway issues a **client ticket** — a signed token that the iOS client presents to the relay to prove it's authorized to connect to that gateway's tunnel stream.

- During pairing (or as a new post-pairing step), the gateway generates: `ticket = HMAC-SHA256(gatewaySecret, deviceId + gatewayId)` and returns it to the iOS client alongside the pairing response.
- The iOS client stores the ticket alongside the gateway record.
- When connecting to the relay tunnel: `/v1/tunnel/<gatewayId>/stream?ticket=<ticket>`.
- The relay forwards the ticket to the gateway (on the upstream WS) for validation. The gateway verifies the HMAC and responds with accept/reject.
- Alternatively (simpler): the relay doesn't validate tickets at all — it just requires one. The real authentication happens at the E2EE layer: if the client can't decrypt responses, it's not paired. The ticket just prevents casual abuse (unauthenticated connections eating relay resources).

**Simpler alternative for Layer 2:** Since E2EE already proves the client holds the shared key, the relay doesn't strictly need to verify client identity. Instead, just rate-limit downstream connections per gateway (e.g., max 10 concurrent clients per gatewayId) to prevent resource exhaustion. The E2EE layer handles the real authentication. If an attacker connects without a shared key, they see only ciphertext and can't decrypt anything.

**Recommendation:** Start with the simpler approach — relay API key for gateways (Layer 1), rate limiting for clients (Layer 2), E2EE handles the rest. Add client tickets later if abuse becomes a problem.

---

## E2EE Design

### Encryption

- **Algorithm:** AES-256-GCM (CryptoKit on iOS, swift-crypto on gateway)
- **Key:** The 256-bit symmetric key derived during X25519 pairing (already exists, stored in Keychain/disk)
- **Nonce:** Random 12-byte nonce per message (included in the envelope)
- **AAD (Additional Authenticated Data):** `type + method + id` concatenated — this lets the relay read routing metadata while still authenticating it against tampering

### Envelope with E2EE

```json
{
  "type": "request",
  "id": "abc-123",
  "method": "printers.list",
  "deviceId": "device-uuid",
  "encrypted": true,
  "nonce": "<base64 12-byte nonce>",
  "payload": "<base64 AES-GCM ciphertext>"
}
```

- `type`, `id`, `method` are plaintext (relay needs them for routing)
- `deviceId` identifies which shared key to use for decryption (gateway may have multiple paired devices)
- `nonce` is the AES-GCM nonce
- `payload` is the encrypted+authenticated ciphertext
- The AAD binds the plaintext header fields to the ciphertext, so the relay can't swap a `printers.list` response into a `printer.command` response

### What the relay sees

```
type: "request"     ← routing (broadcast vs unicast)
id: "abc-123"       ← correlation (route response to correct client)  
method: "printers.list"  ← logging/metrics only
deviceId: "..."     ← opaque identifier
payload: "kJ3x..."  ← opaque ciphertext
```

The relay can route messages but cannot read, modify, or forge payloads.

### Event encryption (broadcast telemetry)

Events are broadcast to all connected clients. Per-client encryption would break the fan-out model. Solution: **Gateway Group Key**.

- When the first device pairs, the gateway generates a random 256-bit **group key**.
- During pairing, the gateway encrypts the group key with the device's individual shared key and includes it in the pairing response: `encryptedGroupKey: "<base64>"`.
- Each paired device decrypts and stores the group key.
- The gateway encrypts all `stream.state` events with the group key.
- All paired devices can decrypt. The relay cannot.
- When a device is unpaired, the gateway rotates the group key and re-issues it to remaining devices on their next connection (via a `key.rotate` event encrypted with each device's individual key).

This makes **all** relay traffic opaque — events, requests, and responses.

---

## Revised Implementation Plan

### Phase 0: Authentication Infrastructure (NEW — do this first)

- [ ] 0.1 **Add gateway registration endpoint to relay** — `POST /v1/gateways/register`
  - Request: `{gatewayId: String, gatewayName: String}`
  - Response: `{apiKey: String}` (random 32-byte hex string)
  - Relay stores `{gatewayId: apiKey}` in a `GatewayRegistry` (in-memory dict + optional JSON persistence).
  - Rate limit: 10 registrations per IP per hour.

- [ ] 0.2 **Validate API key on tunnel connect** — update `TunnelRoutes.handleConnect`
  - Require `?apiKey=<key>` query parameter on `/v1/tunnel/:gatewayId/connect`.
  - Validate against `GatewayRegistry`. Reject with 401 if invalid.

- [ ] 0.3 **Gateway auto-registration** — update `RelayTunnelClient`
  - On first boot (no stored API key), call `POST /v1/gateways/register` to get an API key.
  - Store API key in the persistent data directory alongside gateway identity.
  - Include API key in tunnel connect URL.
  - If tunnel connect returns 401 (key rotated/expired), re-register automatically.

- [ ] 0.4 **Rate-limit downstream tunnel connections** — update `TunnelRoutes.handleStream`
  - Max 10 concurrent downstream clients per gatewayId.
  - Reject with 429 if exceeded.

- [ ] 0.5 **Return `relayApiKey` and `groupKey` during pairing** — update gateway pairing flow
  - Generate a 256-bit group key on first pairing. Store alongside gateway identity.
  - In the `POST /v1/pair` response, add `groupKey: "<base64 encrypted with device shared key>"`.
  - iOS client decrypts and stores the group key in Keychain alongside the shared key.

- [ ] 0.6 **Store group key on iOS** — update `PairingClient` and `AddGatewaySheet`
  - Parse `encryptedGroupKey` from pair response.
  - Decrypt with shared key, store in Keychain at `KeychainStore.gatewayGroupKeyAccount(gatewayId:)`.

### Phase 1: Envelope Protocol + E2EE (Gateway)

- [ ] 1.1 **Create `MessageEnvelope` model** — shared between gateway, iOS, and relay
  - Fields: `type`, `id`, `method`, `deviceId`, `encrypted`, `nonce`, `payload`
  - Create in gateway as `gateway/.../Domain/MessageEnvelope.swift`
  - Create in iOS as `Shared/Domain/MessageEnvelope.swift`
  - Create in relay as `relay/.../Domain/MessageEnvelope.swift`

- [ ] 1.2 **Create `PayloadCrypto` utility** — gateway and iOS
  - `encrypt(payload: Data, key: SymmetricKey, aad: Data) -> (ciphertext: Data, nonce: Data)`
  - `decrypt(ciphertext: Data, nonce: Data, key: SymmetricKey, aad: Data) -> Data`
  - AAD = `"\(type):\(method):\(id ?? "")"` encoded as UTF-8

- [ ] 1.3 **Create `MessageRouter` actor** on gateway
  - Dispatches by `method` string to handler functions.
  - Handles decryption: looks up device's shared key via `deviceId`, decrypts payload if `encrypted: true`.
  - Handlers reuse existing `PrinterService`/`PairingService` logic.
  - Methods: `health`, `printers.list`, `printers.state`, `printers.register`, `printers.remove`, `activities.register`, `printer.command`.

- [ ] 1.4 **Update `StreamRoutes.handleStream`** for envelope protocol
  - Detect protocol version via `?protocol=envelope` query parameter.
  - Envelope clients: send `event` envelopes, accept incoming `request` frames, route to `MessageRouter`.
  - Legacy clients: send raw `PrintJobState` JSON (backward compat).

- [ ] 1.5 **Encrypt broadcast events with group key**
  - `PrinterService.broadcastState()` wraps `PrintJobState` in an `event` envelope.
  - For tunnel-destined frames: encrypt payload with group key, set `encrypted: true`.
  - For local WS clients: send plaintext (they're on LAN, no relay in the path).

- [ ] 1.6 **Encrypt response payloads with device shared key**
  - `MessageRouter` encrypts response payload using the requesting device's shared key.
  - Response envelope has `encrypted: true`, includes `nonce`.

### Phase 2: iOS Speaks Envelopes + E2EE

- [ ] 2.1 **Add `MessageEnvelope` to iOS** (`Shared/Domain/MessageEnvelope.swift`)

- [ ] 2.2 **Add `PayloadCrypto` to iOS** (`Shared/Crypto/PayloadCrypto.swift`)

- [ ] 2.3 **Add request/response API to `GatewayStreamClient`**
  - `func request(_ method: String, payload: Encodable) async throws -> Data`
  - Generates UUID `id`, encrypts payload when on relay (using shared key), sends envelope.
  - Awaits response with matching `id`, decrypts if encrypted, returns payload data.
  - Timeout: 10 seconds.

- [ ] 2.4 **Decrypt incoming events using group key**
  - When `handleMessage` receives an `event` envelope with `encrypted: true`, decrypt payload with group key before decoding as `PrintJobState`.

- [ ] 2.5 **Migrate `GatewaySyncService` to WS request** (`printers.list` method)
  - Falls back to HTTP on LAN if WS unavailable (backward compat with old gateways).

- [ ] 2.6 **Migrate `LiveActivityCoordinator.forwardPushToken()` to WS request** (`activities.register` method)
  - Same HTTP fallback.

- [ ] 2.7 **Add `GatewayAdapter.request()` pass-through** for higher-level code.

### Phase 3: Relay Goes Bidirectional

- [ ] 3.1 **Add upstream forwarding in `TunnelRoutes.handleStream`**
  - `ws.onText` handler forwards client frames to the gateway's upstream WebSocket.

- [ ] 3.2 **Add response routing in `TunnelBroker`**
  - `event` type → fan-out to all downstream clients (broadcast).
  - `response`/`error` type → route to the client that sent the matching request `id`.
  - `pendingRoutes: [String: UUID]` map with 30-second TTL expiry.

- [ ] 3.3 **The relay never reads payloads** — it only inspects `type` and `id` from the envelope for routing. All routing decisions use plaintext envelope headers. Payloads are opaque ciphertext.

### Phase 4: Printer Commands

- [ ] 4.1 **Add `printer.command` handler** in gateway `MessageRouter`
  - Maps `{printerId, command}` to Bambu MQTT publish.

- [ ] 4.2 **Add command UI in iOS `PrinterDetailView`**
  - Pause/Resume/Cancel buttons. Send `printer.command` request via `GatewayAdapter.request()`.

- [ ] 4.3 **Add `printers.register` and `printers.remove` WS methods**
  - Users can manage printers from the iOS app, anywhere.

### Phase 5: Group Key Rotation

- [ ] 5.1 **Rotate group key when a device is unpaired**
  - Gateway generates new group key, re-encrypts for each remaining paired device.
  - Sends `key.rotate` event (encrypted with each device's individual shared key) on the next connection.

- [ ] 5.2 **iOS handles `key.rotate` events**
  - Decrypts new group key with individual shared key, updates Keychain.

---

## Security Properties (what we guarantee)

| Property | Mechanism | Verified By |
|----------|-----------|-------------|
| **Confidentiality** | AES-256-GCM encryption of all payloads | Relay logs show only ciphertext |
| **Integrity** | GCM authentication tag + AAD binding | Tampered messages fail MAC verification |
| **Authentication (gateway → relay)** | Relay API key from registration | Relay rejects unregistered gateways |
| **Authentication (iOS → gateway)** | E2EE — only paired devices can decrypt | Unpaired devices see ciphertext only |
| **Non-impersonation** | Gateway signs events with group key; responses with device key | iOS verifies MAC on every message |
| **Forward secrecy** | Not currently (static shared key). Future: ratchet protocol | -- |
| **Replay protection** | Random nonce per message + GCM | Replayed message has same nonce, GCM rejects duplicate context |
| **Relay zero-knowledge** | Payloads encrypted before reaching relay | Relay code never calls decrypt |
| **Abuse prevention** | Rate limiting on registration + downstream connections | Relay rejects excessive connections |

## What the relay CAN still see (metadata)

Even with full E2EE, the relay knows:
- Which gateway IDs are connected (it needs this for routing)
- How many clients are connected per gateway
- Message frequency and sizes (traffic analysis)
- When gateways/clients connect and disconnect

This is inherent to any relay/proxy architecture. Full metadata protection would require something like Tor or mixnets, which is overkill for a printer monitoring app.

---

## Verification Criteria

- [ ] A paired iOS client on relay can list printers, register push tokens, and send commands — same as LAN.
- [ ] An unpaired device connecting to the relay tunnel receives only ciphertext it cannot decrypt.
- [ ] The relay server logs show zero plaintext printer data (names, temps, progress, etc.).
- [ ] Removing a paired device from the gateway triggers group key rotation; the removed device can no longer decrypt events.
- [ ] A compromised relay cannot forge a valid `response` or `event` envelope (MAC verification fails on iOS).
- [ ] Gateway registration prevents impersonation: a fake gateway cannot push data to real iOS clients.
- [ ] The system works with Cloudflare proxying (TLS termination at edge) without weakening E2EE guarantees.
