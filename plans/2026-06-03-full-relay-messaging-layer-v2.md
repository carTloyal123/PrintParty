# Full Relay Messaging Layer — Detailed Implementation Plan

## Objective

Replace the current split architecture (HTTP REST for reads/writes + one-way WebSocket for state streaming) with a **unified bidirectional WebSocket protocol** that works identically on LAN and through the relay. This gives users the same experience whether they're at home or away, and unifies development so every new feature works over both paths automatically.

## Current Architecture Problems

### The Split Protocol Problem
Today the iOS client uses two completely different communication channels:

1. **HTTP REST** — for requests (`GET /v1/printers`, `POST /v1/activities`, `GET /healthz`)
2. **WebSocket** — for the real-time state stream (`/v1/stream`, read-only)

These are separate connection paths, and only the WebSocket has relay tunnel support. The HTTP endpoints are LAN-only because the relay can't proxy HTTP — it only forwards WebSocket frames.

### The One-Way Tunnel Problem
The relay's `TunnelBroker` (`relay/.../TunnelRoutes.swift:19-117`) is a **broadcast-only fan-out**:
- Gateway sends text frames on the upstream WebSocket → relay fans them out to all downstream iOS clients
- iOS clients send nothing upstream — `handleStream` (`TunnelRoutes.swift:167-190`) never registers an `onText` handler for client frames

This means even if the iOS client could formulate a request, the relay would drop it on the floor.

### Impact on Users
When away from home (on relay), users **cannot**:
- Sync new printers added to the gateway
- Register push tokens for Live Activities
- Send printer commands (pause/resume/cancel)
- Check gateway health

They can only passively watch the state stream.

---

## Alternatives Considered

### Option A: HTTP Reverse Tunnel
Make the relay proxy HTTP requests verbatim to the gateway by having the gateway maintain an HTTP reverse tunnel (like ngrok/Cloudflare Tunnel).

**Pros:** No protocol changes on gateway or iOS — existing HTTP endpoints "just work" remotely.
**Cons:**
- Requires a persistent HTTP tunnel connection from gateway → relay, separate from the WebSocket tunnel. Two outbound connections to maintain.
- The relay needs to become an HTTP proxy with request routing, buffering, and timeout handling. Significantly more complex than WebSocket frame forwarding.
- HTTP is request-response per connection — high overhead for the real-time stream. We'd still need the WebSocket stream alongside the HTTP tunnel, perpetuating the split protocol.
- Hard to add E2EE: each HTTP request/response would need independent encryption, with no shared session context.

**Verdict:** Solves the remote access problem but doesn't unify the protocol. Increases complexity on both relay and gateway. Rejected.

### Option B: MQTT Broker as Relay
Replace the custom relay with a hosted MQTT broker (e.g., Mosquitto, HiveMQ). The gateway publishes state on topics like `gw/<gatewayId>/state`, and iOS clients subscribe. Commands go on `gw/<gatewayId>/command`.

**Pros:** MQTT is designed for IoT pub/sub. Broker handles fan-out, persistence, QoS, last-will. Already the internal protocol (Bambu printers use MQTT).
**Cons:**
- Adds a new runtime dependency (MQTT broker) to the relay infrastructure. Currently the relay is a single stateless Swift binary.
- iOS clients would need an MQTT client library (no built-in MQTT in iOS). Additional dependency in the app.
- MQTT doesn't natively support request/response correlation. Would need to build that on top (like MQTT 5.0 response topics), adding complexity.
- Harder to add E2EE — MQTT brokers inspect topic routing, so we'd need per-topic encryption or a custom payload layer.
- Different protocol than what we use for LAN (HTTP+WS), so doesn't unify development.

**Verdict:** Powerful for pure pub/sub but overkill for our needs. Introduces new dependencies without unifying the LAN/relay experience. Rejected.

### Option C: gRPC Bidirectional Streaming
Use gRPC with bidirectional streaming between iOS ↔ relay ↔ gateway.

**Pros:** Strongly typed, code-generated, built-in streaming. HTTP/2 multiplexing.
**Cons:**
- Heavy dependency (protobuf + gRPC runtime) on all three components.
- Not natively supported in Vapor — would require replacing the web framework or running a parallel gRPC server.
- iOS gRPC libraries add significant binary size.
- Not debuggable with standard browser/curl tools.
- WebSocket is already deployed and working.

**Verdict:** Over-engineered for our scale. Rejected.

### Option D: Unified Bidirectional WebSocket with JSON Envelopes (CHOSEN)
Put all communication — events, requests, and responses — on the same WebSocket connection using a simple JSON envelope protocol.

**Pros:**
- **Unified protocol** — one connection carries everything, LAN and relay.
- **Zero new dependencies** — uses existing WebSocket infrastructure on all three components.
- **Simple to debug** — JSON text frames, readable with any WebSocket tool.
- **Relay stays simple** — just forwards frames in both directions, no HTTP parsing.
- **E2EE fits naturally** — encrypt the `payload` field per-message, relay can still route by `type`/`id`.
- **Backward compatible** — gateway can auto-detect legacy clients (raw `PrintJobState` frames) and serve them the old way.
- **Future-proof** — adding new methods is just adding a new `method` string handler, no new endpoints.

**Cons:**
- Requires protocol changes on all three components (gateway, iOS, relay).
- Request/response over WebSocket needs correlation ID management (straightforward to implement).
- The gateway currently has well-tested HTTP route handlers that need to be refactored into method handlers (but the logic is the same).

**Verdict:** Best balance of simplicity, unification, and extensibility. Chosen.

---

## Message Envelope Specification

### Wire Format

Every WebSocket text frame is a JSON object with this shape:

```json
{
  "type": "event" | "request" | "response" | "error",
  "id": "optional-uuid-for-correlation",
  "method": "stream.state" | "health" | "printers.list" | ...,
  "payload": { ... method-specific data ... },
  "encrypted": false
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | `event` = server push, `request` = client asks, `response` = server answers, `error` = server error reply |
| `id` | string | for req/resp | UUID generated by the client, echoed in the response. Events have no `id`. |
| `method` | string | yes | Identifies the operation. Namespaced: `stream.state`, `printers.list`, etc. |
| `payload` | object/string | yes | Method-specific data. When `encrypted: true`, this is a base64 string of AES-GCM ciphertext. |
| `encrypted` | bool | no | Defaults to `false`. When `true`, `payload` is encrypted with the pairing shared key. |

### Error Response

```json
{
  "type": "error",
  "id": "same-as-request",
  "method": "printers.list",
  "payload": { "code": "not_found", "message": "printer not found" }
}
```

### Method Catalog

#### Events (gateway → client, no `id`)

| Method | Payload | Replaces |
|--------|---------|----------|
| `stream.state` | `PrintJobState` object | Raw WS stream frames |

#### Request/Response (client → gateway → client)

| Method | Request Payload | Response Payload | Replaces |
|--------|----------------|-----------------|----------|
| `health` | `{}` | `{status, version, gatewayId, gatewayName, relayURL, printers: [...]}` | `GET /healthz` |
| `printers.list` | `{}` | `[{id, displayName, modelName, stage, progressPercent}]` | `GET /v1/printers` |
| `printers.state` | `{printerId}` | `PrintJobState` | `GET /v1/printers/:id/state` |
| `printers.register` | `{displayName, modelName, host, serial, accessCode}` | `{printerId, status}` | `POST /v1/printers` |
| `printers.remove` | `{printerId}` | `{status}` | `DELETE /v1/printers/:id` |
| `activities.register` | `{printerId, pushToken, sharedKey?}` | `{status}` | `POST /v1/activities` |
| `printer.command` | `{printerId, command: "pause"/"resume"/"cancel"}` | `{status}` | (new) |

---

## Implementation Plan

### Phase 1: Shared Envelope Model + Gateway Protocol

**Goal:** Gateway speaks the new envelope protocol on `/v1/stream`. Legacy raw-stream clients still work. No iOS or relay changes yet.

- [ ] 1.1 **Create `MessageEnvelope` model** — new file `gateway/Sources/PrintPartyGateway/Domain/MessageEnvelope.swift`
  - `struct MessageEnvelope: Codable` with `type`, `id`, `method`, `payload` (as `AnyCodableValue` or raw `String`/`Data`), `encrypted`.
  - `enum MessageType: String, Codable { case event, request, response, error }`.
  - Helper: `static func event(method:payload:)`, `static func response(id:method:payload:)`, `static func error(id:method:code:message:)`.

- [ ] 1.2 **Create `MessageRouter` actor** — new file `gateway/Sources/PrintPartyGateway/Messaging/MessageRouter.swift`
  - Receives decoded `MessageEnvelope` requests, dispatches to handler functions by `method` string.
  - Each handler takes a `payload: Data` and returns a response `payload: Data` (or throws for error responses).
  - Handlers are thin wrappers around existing `PrinterService` and `PairingService` methods — reuse the exact same logic that today's HTTP route handlers call.
  - Methods: `health`, `printers.list`, `printers.state`, `printers.register`, `printers.remove`, `activities.register`.

- [ ] 1.3 **Update `StreamRoutes.handleStream`** (`gateway/.../Routes/StreamRoutes.swift`)
  - On connect, send current printer states wrapped in `event` envelopes (instead of raw `PrintJobState` JSON).
  - Register a `ws.onText` handler that:
    1. Tries to decode the frame as `MessageEnvelope`.
    2. If it's a `request`, route to `MessageRouter`, get response, send back on the same WS.
    3. If decoding fails, this is a legacy client — ignore (they don't send upstream frames anyway).
  - Ongoing state broadcasts from `PrinterService.broadcastState()`: wrap each `PrintJobState` in an `event` envelope before sending.

- [ ] 1.4 **Update `PrinterService.broadcastState()`** (`gateway/.../Printers/PrinterService.swift:312`)
  - Change the JSON encoding to produce `MessageEnvelope` with `type: .event, method: "stream.state"` wrapping the `PrintJobState`.
  - The tunnel client (`RelayTunnelClient.send(text:)`) gets the same envelope-formatted string — this is important for Phase 2 compatibility.

- [ ] 1.5 **Auto-detect legacy clients** on the gateway WS.
  - Track a `isLegacy` flag per WS client. Default `false`.
  - If the first outgoing envelope is the initial state dump and the client disconnects immediately (common with old clients that can't parse envelopes), or if the gateway receives a raw non-envelope frame from the client, flip `isLegacy = true` for that client and send raw `PrintJobState` JSON going forward.
  - Simpler approach: add a query parameter `?protocol=envelope` to the WS URL. Clients that include it get envelopes; others get legacy raw frames. The iOS app adds the parameter when it's updated; older apps don't. Gateway checks on connect.

### Phase 2: iOS Client Speaks Envelopes

**Goal:** iOS `GatewayStreamClient` sends/receives envelopes. HTTP calls migrated to WS requests.

- [ ] 2.1 **Create iOS `MessageEnvelope` model** — new file `Shared/Domain/MessageEnvelope.swift` (shared between app and widget).
  - Mirror of the gateway's `MessageEnvelope`. Since both sides are Swift and share the same `Codable` format, the wire format is identical.

- [ ] 2.2 **Add request/response infrastructure to `GatewayStreamClient`**
  - New property: `private var pendingRequests: [String: CheckedContinuation<MessageEnvelope, Error>] = [:]`
  - New method: `func request(_ method: String, payload: Encodable) async throws -> MessageEnvelope`
    - Generates a UUID `id`, encodes the request envelope, sends it as a text frame.
    - Stores a continuation keyed by `id`.
    - When a `response` or `error` frame arrives with that `id`, resumes the continuation.
    - Timeout: 10 seconds, then resume with a timeout error.
  - Update `handleMessage()` to decode frames as `MessageEnvelope`:
    - `event` with `method: "stream.state"` → decode `payload` as `PrintJobState`, yield to continuations (existing path).
    - `response` or `error` → look up `pendingRequests[id]`, resume continuation.

- [ ] 2.3 **Add `?protocol=envelope` to WS URL** in `GatewayStreamClient.buildWebSocketURL()`.
  - Append query parameter so the gateway knows to send envelopes instead of raw frames.

- [ ] 2.4 **Migrate `GatewaySyncService`** from HTTP to WS request.
  - Instead of `URLSession.shared.data(for:)` to `GET /v1/printers`, call `streamClient.request("printers.list", payload: EmptyPayload())`.
  - This requires `GatewaySyncService` to have access to the stream client. Thread this through via `GatewayAdapter` or `AdapterRegistry`.
  - Fallback: if the WS request fails (e.g., no active connection), fall back to the existing HTTP call on LAN. This handles the transition period where the gateway hasn't been updated yet.

- [ ] 2.5 **Migrate `LiveActivityCoordinator.forwardPushToken()`** from HTTP to WS request.
  - Instead of `POST /v1/activities`, call `streamClient.request("activities.register", payload: ...)`.
  - Same fallback to HTTP on failure.

- [ ] 2.6 **Add `GatewayAdapter.request()` pass-through** so higher-level code can make requests without directly accessing the stream client.
  - `func request(_ method: String, payload: Encodable) async throws -> MessageEnvelope`
  - Delegates to the internal `streamClient`.

### Phase 3: Relay Becomes Bidirectional

**Goal:** The relay forwards frames in both directions. iOS clients can make requests through the relay to their gateway.

- [ ] 3.1 **Add upstream forwarding in `TunnelRoutes.handleStream`** (`relay/.../TunnelRoutes.swift:167`)
  - Currently the downstream handler only registers for fan-out and sends pings. Add:
    ```swift
    ws.onText { ws, text in
        broker.forwardUpstream(gatewayId: gatewayId, clientId: clientId, text: text)
    }
    ```
  - `TunnelBroker.forwardUpstream()`: looks up the upstream (gateway) WebSocket for the given `gatewayId` and sends the text frame.

- [ ] 3.2 **Add response routing in `TunnelBroker`**
  - When the gateway sends a frame downstream, the broker currently fans it out to all clients.
  - New logic: peek at the frame's `type` field (lightweight JSON parse — just the first ~20 chars).
    - `"type":"event"` → fan-out to all downstream clients (broadcast, same as today).
    - `"type":"response"` or `"type":"error"` → extract the `id`, look up which client sent the request with that `id`, send only to that client.
  - The broker maintains a `pendingRoutes: [String: UUID]` map (request `id` → client UUID). When a client frame is forwarded upstream, the broker extracts the `id` and records the mapping. When a response comes back, it routes and removes the mapping.
  - TTL: entries expire after 30 seconds to prevent leaks from lost responses.

- [ ] 3.3 **Thread safety for `pendingRoutes`**
  - Add the map inside `TunnelBroker` under the existing `NIOLock`.
  - Clean up expired entries periodically (e.g., in the ping timer loop).

### Phase 4: E2EE for Relay Traffic

**Goal:** Request/response payloads are encrypted end-to-end when going through the relay.

- [ ] 4.1 **Create `PayloadCrypto` utility** in `Shared/` (iOS) and gateway.
  - `static func encrypt(payload: Data, key: SymmetricKey) -> (ciphertext: Data, nonce: Data)`
  - `static func decrypt(ciphertext: Data, nonce: Data, key: SymmetricKey) -> Data`
  - Uses AES-256-GCM (CryptoKit on iOS, swift-crypto on Linux).

- [ ] 4.2 **iOS: encrypt request payloads when `connectionMode == .relay`**
  - In `GatewayStreamClient.request()`, if currently on relay:
    - Encrypt the payload JSON with the shared key.
    - Set `encrypted: true` on the envelope.
    - Encode `payload` as base64 ciphertext string.
  - On LAN: send plaintext (skip encryption overhead).

- [ ] 4.3 **Gateway: decrypt incoming request payloads**
  - `MessageRouter` checks `encrypted` flag.
  - Looks up the shared key for the device (from `PairingService` stored pairings).
  - Decrypts before processing.
  - Device identification: the gateway knows which device is asking because the upstream tunnel WebSocket connection from the relay carries a `clientId` injected by the relay, or the request includes a `deviceId` field.

- [ ] 4.4 **Gateway: encrypt response payloads**
  - If the request was encrypted, encrypt the response payload with the same key and set `encrypted: true`.

- [ ] 4.5 **Events stay plaintext on the tunnel**
  - The tunnel broadcast is shared across all clients. Encrypting per-client would require per-client tunnel connections (breaking the fan-out model).
  - Telemetry events are not secret from the user — they're the same data shown on the LAN WS. The relay can see temperature and progress data, but it can't modify it (integrity is ensured by the fact that only the gateway produces events).
  - If per-event encryption is ever needed, it could use a "group key" shared across all paired devices for a gateway, but this is unnecessary for now.

### Phase 5: Printer Commands

**Goal:** Users can pause/resume/cancel prints from the iOS app, whether on LAN or relay.

- [ ] 5.1 **Add `printer.command` handler in gateway `MessageRouter`**
  - Accepts `{printerId: UUID, command: String}`.
  - Maps command strings to Bambu MQTT messages:
    - `"pause"` → publish `{"print":{"command":"pause","sequence_id":"0"}}` to `device/<serial>/request`
    - `"resume"` → publish `{"print":{"command":"resume","sequence_id":"0"}}`
    - `"cancel"` → publish `{"print":{"command":"stop","sequence_id":"0"}}`
  - Returns `{status: "sent"}` or error if printer not found.

- [ ] 5.2 **Add command UI in iOS `PrinterDetailView`**
  - Replace the current "Commands will be added in a future update" placeholder (`PrinterDetailView.swift:267-282`).
  - Show Pause/Resume/Cancel buttons based on current `PrintJobState.stage`.
  - Buttons call `adapter.request("printer.command", payload: ...)`.
  - Works identically on LAN and relay — the envelope protocol handles the routing.

- [ ] 5.3 **Add `printers.register` and `printers.remove` WS methods**
  - Let users add/remove Bambu printers from the iOS app (currently only possible via gateway CLI).
  - The existing `PrinterRoutes` handlers contain the logic — just wire them up as `MessageRouter` methods.

---

## Migration Path (Phased Rollout)

| Phase | Gateway | iOS | Relay | User Impact |
|-------|---------|-----|-------|-------------|
| **1** | Speaks envelopes on WS, keeps HTTP endpoints | No change (still HTTP + raw WS) | No change | Zero — existing clients unaffected |
| **2** | Same | Speaks envelopes, HTTP fallback | No change | iOS uses WS for everything on LAN; relay still read-only |
| **3** | Same | Same | Bidirectional forwarding | Full remote access — requests work through relay |
| **4** | Decrypts/encrypts | Encrypts/decrypts on relay | Transparent | Relay becomes zero-knowledge |
| **5** | Command handler | Command UI | Same | Users can control printers from anywhere |

Each phase is independently deployable and backward-compatible. Users can update gateway and iOS independently without breaking anything.

## Verification Criteria

- [ ] **LAN parity:** iOS on LAN can do everything via WS that it previously did via HTTP + WS.
- [ ] **Relay parity:** iOS on relay can do everything that LAN can (except initial pairing, which requires LAN proximity by design).
- [ ] **Backward compat:** An old iOS client (pre-envelope) connecting to a new gateway still works.
- [ ] **A new iOS client connecting to an old gateway still works** (falls back to HTTP for requests).
- [ ] **E2EE:** Relay cannot read request/response payloads. Verified by inspecting relay logs.
- [ ] **Commands:** Pause/resume/cancel from iOS works on both LAN and relay. Printer responds correctly.
- [ ] **Latency:** Request/response through relay completes within 2 seconds under normal conditions.
