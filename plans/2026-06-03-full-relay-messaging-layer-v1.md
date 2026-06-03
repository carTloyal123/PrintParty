# Full Relay Messaging Layer — Bidirectional Gateway Access from Anywhere

## Objective

Transform the relay from a one-way `PrintJobState` forwarder into a **full bidirectional message broker** that lets iOS clients interact with their gateway exactly as if they were on LAN — while keeping all traffic encrypted end-to-end with the shared pairing key.

## Current Architecture (read-only tunnel)

```
iOS (LAN)  ───HTTP REST──────► Gateway ◄──MQTT──► Printer
iOS (LAN)  ◄──WS /v1/stream── Gateway

iOS (away) ◄──WS tunnel────── Relay ◄──WS tunnel── Gateway
                               (text frame fan-out, one-way)
```

**What works on LAN but NOT through the relay:**
- `GET /healthz` — gateway health + printer status
- `GET /v1/printers` — printer list sync
- `POST /v1/activities` — push token registration
- Any future commands (pause, cancel, resume, etc.)

**Root cause:** The relay tunnel is a unidirectional text-frame fan-out. The iOS client has no way to send messages *upstream* through the tunnel to the gateway.

## Proposed Architecture (bidirectional message broker)

```
iOS ◄──────WS──────► Relay ◄──────WS──────► Gateway ◄──MQTT──► Printer
              │                     │
         bidirectional         bidirectional
         JSON envelope         JSON envelope
```

A single WebSocket connection (LAN or relay) carries **both** directions:
- **Gateway → iOS:** printer state updates (existing), responses to requests
- **iOS → Gateway:** requests (health, printer list, push token, future commands)

The relay becomes a **transparent bidirectional pipe** — it forwards envelopes in both directions without inspecting content. E2EE can wrap the payload so the relay is zero-knowledge.

## Message Envelope Design

Every frame on the WebSocket (both directions) is a JSON envelope:

```json
{
  "type": "request" | "response" | "event",
  "id": "uuid-for-request-response-correlation",
  "method": "health" | "printers.list" | "printers.state" | "activities.register" | "stream.state" | ...,
  "payload": { ... }
}
```

- **`event`** — server-initiated push (no `id`). The current `PrintJobState` stream becomes `{"type":"event","method":"stream.state","payload":{...PrintJobState...}}`.
- **`request`** — client-initiated, carries a correlation `id`.
- **`response`** — gateway reply to a request, echoes the same `id`.

This is essentially JSON-RPC over WebSocket, keeping it simple and debuggable.

### Message Methods (initial set)

| Method | Direction | Replaces | Description |
|--------|-----------|----------|-------------|
| `stream.state` | event (gw → ios) | WS `/v1/stream` frames | Real-time PrintJobState updates |
| `health` | req/resp | `GET /healthz` | Gateway health + printer summary |
| `printers.list` | req/resp | `GET /v1/printers` | List registered printers |
| `printers.state` | req/resp | `GET /v1/printers/:id/state` | Single printer state |
| `printers.register` | req/resp | `POST /v1/printers` | Register a new printer |
| `printers.remove` | req/resp | `DELETE /v1/printers/:id` | Unregister a printer |
| `activities.register` | req/resp | `POST /v1/activities` | Push token registration |
| `printer.command` | req/resp | (new) | Pause/resume/cancel/etc. |

### E2EE Layer (optional per-message)

For relay-tunneled connections, the `payload` field can be encrypted using the shared symmetric key from the X25519 pairing:

```json
{
  "type": "request",
  "id": "...",
  "method": "printers.list",
  "encrypted": true,
  "payload": "<base64 AES-GCM ciphertext of the actual payload JSON>"
}
```

The relay sees `type`, `id`, `method` (for routing/logging) but cannot read the payload. On LAN, encryption is optional (skip the overhead). The iOS client decides based on `connectionMode`:
- `.lan` → plaintext payloads
- `.relay` → encrypted payloads

## Implementation Plan

### Phase 1: Bidirectional WebSocket Protocol (Gateway + iOS)

- [ ] 1.1 **Define `MessageEnvelope` model** in `Shared/` so both gateway and iOS share the type.
  ```
  struct MessageEnvelope: Codable {
      let type: MessageType  // .request, .response, .event
      let id: String?
      let method: String
      let payload: AnyCodable  // or Data/String for flexibility
      let encrypted: Bool?
  }
  ```

- [ ] 1.2 **Update gateway `StreamRoutes`** to use the envelope protocol.
  - Wrap outgoing `PrintJobState` in `{"type":"event","method":"stream.state","payload":{...}}`.
  - Listen for incoming text frames (currently the gateway ignores client-to-server messages on the WS).
  - Route incoming `request` envelopes to a `MessageRouter` that dispatches by `method`.

- [ ] 1.3 **Build gateway `MessageRouter`** that maps method strings to handler functions.
  - `health` → return the same data as `GET /healthz`
  - `printers.list` → return `PrinterService.registeredPrinters()` + states
  - `printers.state` → return single printer state
  - `activities.register` → call `PrinterService.registerPushToken()`
  - Each handler returns a response envelope with the same `id`.

- [ ] 1.4 **Update iOS `GatewayStreamClient`** to speak the envelope protocol.
  - Parse incoming frames as `MessageEnvelope` instead of raw `PrintJobState`.
  - For `event` type with `method: "stream.state"`, decode payload as `PrintJobState` (existing path).
  - For `response` type, route to pending request continuations.

- [ ] 1.5 **Add request/response API to `GatewayStreamClient`**.
  - `func request(_ method: String, payload: Encodable) async throws -> MessageEnvelope`
  - Generates a UUID `id`, sends the request envelope, awaits the response with matching `id` via a continuation map.
  - Timeout after 10s if no response.

- [ ] 1.6 **Migrate `GatewaySyncService`** from HTTP `GET /v1/printers` to WebSocket `printers.list` request.
  - Fall back to HTTP on LAN if the WS request/response isn't available (backward compat with older gateways).

- [ ] 1.7 **Migrate `LiveActivityCoordinator.forwardPushToken()`** from HTTP `POST /v1/activities` to WebSocket `activities.register` request.
  - Same fallback strategy for backward compat.

### Phase 2: Relay Becomes Bidirectional

- [ ] 2.1 **Update relay `TunnelRoutes` downstream handler** to forward client frames upstream.
  - Currently `handleStream` only registers the client for fan-out and sends pings; it ignores incoming frames from iOS clients.
  - Add `ws.onText` handler that routes incoming frames from iOS → gateway's upstream WebSocket.

- [ ] 2.2 **Update relay `TunnelRoutes` upstream handler** to route responses to the correct client.
  - Currently `handleConnect` fans out all gateway frames to all downstream clients.
  - For `event` type: continue fan-out to all clients (broadcast).
  - For `response` type: route only to the client that sent the matching `request` (use the `id` field or a client-addressed routing header).

- [ ] 2.3 **Add client addressing to the relay.**
  - Option A: The envelope gets a `clientId` field that the relay injects on upstream forwarding. The gateway echoes it in the response. The relay uses it to route the response back.
  - Option B: The relay maintains a pending-request map: `{requestId: clientUUID}` and routes responses by matching `id`.
  - Option B is simpler and doesn't require the gateway to know about relay internals. The relay just remembers which client sent each request ID.

### Phase 3: E2EE for Relay Traffic

- [ ] 3.1 **Add `PayloadEncryptor` utility** in `Shared/` using AES-256-GCM with the shared symmetric key from pairing.
  - Encrypt: `(plaintext: Data, key: SymmetricKey) -> (ciphertext: Data, nonce: Data)`
  - Decrypt: `(ciphertext: Data, nonce: Data, key: SymmetricKey) -> Data`

- [ ] 3.2 **iOS client encrypts request payloads when on relay.**
  - `GatewayStreamClient` checks `connectionMode == .relay` before sending.
  - Sets `encrypted: true` on the envelope, encrypts `payload` with the shared key.

- [ ] 3.3 **Gateway decrypts incoming request payloads.**
  - `MessageRouter` checks `encrypted` flag, looks up the shared key for the device (from pairing records), decrypts before processing.

- [ ] 3.4 **Gateway encrypts response payloads when the request was encrypted.**
  - Echoes `encrypted: true` and uses the same shared key.

- [ ] 3.5 **Gateway encrypts event payloads for relay-connected clients.**
  - This is trickier: the gateway's tunnel WebSocket is shared across all clients, but each client may have a different shared key.
  - Option A: Send plaintext events on the tunnel (they're already visible via the LAN WS anyway — telemetry isn't secret from the user).
  - Option B: Per-client encryption (requires the relay to maintain per-client tunnel connections instead of fan-out).
  - **Recommendation: Option A** for events (broadcast telemetry), Option B only for request/response (per-client secrets).

### Phase 4: Printer Commands (Future)

- [ ] 4.1 **Add `printer.command` method** to the gateway `MessageRouter`.
  - Accepts `{printerId, command: "pause" | "resume" | "cancel" | "pushall"}`.
  - Routes to `PrinterService` which publishes the appropriate MQTT command to the Bambu printer.

- [ ] 4.2 **Add command UI in iOS `PrinterDetailView`.**
  - Pause/Resume/Cancel buttons that send `printer.command` requests over the WebSocket.
  - Works identically on LAN and relay — the gateway handles the command and sends MQTT.

- [ ] 4.3 **Add `printers.register` and `printers.remove` methods.**
  - Let users add/remove printers from the iOS app remotely.

## Backward Compatibility Strategy

- The gateway continues to serve existing HTTP REST endpoints. Older iOS clients that don't speak the envelope protocol still work on LAN via HTTP + raw WS stream.
- The envelope protocol is opt-in: the gateway detects whether a WS client speaks envelopes by checking if the first frame it receives is a valid `MessageEnvelope`. If not, it falls back to raw `PrintJobState` fan-out (legacy mode).
- The relay tunnel is already versioned at `/v1/tunnel/...`. The new bidirectional protocol can live at the same path — the relay just needs to start forwarding client frames upstream (currently it ignores them, so there's no conflict).

## Verification Criteria

- iOS client on LAN: WebSocket carries both state events and request/response (health, printer list, push token registration)
- iOS client on relay: same capabilities as LAN, with encrypted payloads
- Relay: zero-knowledge of payload content; only sees envelope metadata for routing
- Gateway: backward-compatible with legacy raw-stream iOS clients
- Printer commands (Phase 4): pause/resume works from both LAN and relay

## Risks and Mitigations

1. **Request/response timeout on relay** — higher latency through Cloudflare + relay. Mitigation: 10s timeout with retry, UI shows "requesting..." indicator.

2. **Response routing at the relay** — relay must correctly route responses to the right client. Mitigation: simple request-ID-to-clientUUID map with TTL expiry (30s).

3. **Breaking older iOS clients** — envelope format change could break existing WS parsing. Mitigation: gateway auto-detects legacy clients and falls back to raw stream mode.

4. **E2EE key mismatch** — if a device re-pairs with a different key, old encrypted messages fail. Mitigation: include a key fingerprint in the envelope so the gateway can detect mismatches and request re-auth.

## Alternative Approaches

1. **HTTP proxy through relay** — relay proxies HTTP requests verbatim to the gateway. Simpler but requires the gateway to be HTTP-addressable from the relay (currently it's outbound-only WS). Would need the gateway to maintain an HTTP reverse tunnel or the relay to initiate connections to the gateway.

2. **gRPC bidirectional streaming** — more structured protocol but adds a dependency and complexity. JSON-over-WS is simpler, debuggable with browser tools, and already the established pattern.

3. **MQTT broker as relay** — use an MQTT broker (like Mosquitto) as the relay. Natural pub/sub model but introduces a new protocol dependency and makes the relay heavier. WebSocket is already deployed and works.
