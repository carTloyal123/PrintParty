# Relay-Proxied WebSocket Tunnel with LAN-First Fallback

## Objective

Give every PrintParty user seamless remote access to their gateway without any networking knowledge, port forwarding, or third-party tunnels — while always preferring the faster LAN connection when available.

## How It Works (User Perspective)

The user does nothing. They pair their gateway once on their home Wi-Fi, add their printer, and leave. When they walk out the door:

1. The iOS app detects the LAN WebSocket is unreachable
2. It automatically connects through the relay's WebSocket proxy
3. Live data keeps flowing — same UI, same experience, slightly higher latency
4. When they come home, the app detects the LAN is reachable again and silently switches back

No settings, no URLs to configure, no "remote mode" toggle.

## Architecture

```
  At Home (LAN):
  iPhone ──WebSocket──▶ Gateway:8080/v1/stream     (direct, ~1ms)

  Away from Home (relay tunnel):
  iPhone ──WSS──▶ Relay/v1/tunnel/<gwId>/stream ──bridges──▶ Gateway (outbound WS)
                         ▲                                       │
                         └───── relay brokers frames ────────────┘
```

### Gateway → Relay: Persistent Outbound Connection

The gateway opens a WebSocket to the relay on startup and keeps it alive:

```
ws://relay:8090/v1/tunnel/<gatewayId>/connect
```

This is an **outbound** connection from the gateway — it punches through NAT, firewalls, and Docker networks without any port forwarding. The gateway sends telemetry frames over this connection whenever printer state changes (the same JSON it sends over the LAN WebSocket).

### Relay: Stateless WebSocket Broker

The relay gains two new routes:

- `GET /v1/tunnel/:gatewayId/connect` — gateway connects here (upstream)
- `GET /v1/tunnel/:gatewayId/stream` — iOS app connects here (downstream)

The relay holds both WebSockets in memory and forwards frames between them. No storage, no database — just a `[String: WebSocket]` map for upstream gateways and `[String: [WebSocket]]` for downstream iOS clients. When a gateway sends a frame, the relay fans it out to all connected iOS clients for that gateway.

### iOS App: LAN-First with Relay Fallback

The `GatewayStreamClient` connection strategy becomes:

```
1. Try LAN WebSocket (gateway's local IP)
   ├── Success → use LAN (green dot, "Gateway" label)
   └── Failure (timeout/unreachable after 5s) →
       2. Try relay tunnel WebSocket (relay URL + gatewayId)
          ├── Success → use relay (blue dot, "Remote" label)
          └── Failure → offline (rely on APNs push fallback)
```

When connected via relay, if the LAN becomes reachable (NWPathMonitor detects home Wi-Fi), the client probes the LAN connection and switches back seamlessly.

## Implementation Plan

### Phase 1: Relay — Tunnel routes

- [ ] Task 1.1. Add `TunnelRoutes` route collection to the relay with two WebSocket endpoints:
  - `GET /v1/tunnel/:gatewayId/connect` — gateway upstream registration
  - `GET /v1/tunnel/:gatewayId/stream` — iOS downstream subscription
- [ ] Task 1.2. Add a `TunnelBroker` actor to the relay that manages:
  - `upstreams: [String: WebSocket]` — one gateway per gatewayId
  - `downstreams: [String: [WebSocket]]` — multiple iOS clients per gatewayId
  - `forward(gatewayId:frame:)` — fans out a gateway frame to all downstream clients
  - `register/unregister` for both sides with cleanup on close
- [ ] Task 1.3. When a gateway WebSocket sends a text frame, the broker forwards it to all connected iOS clients for that gatewayId. When an iOS client disconnects, it's removed from the downstream list. When the gateway disconnects, all downstream clients receive a close frame.
- [ ] Task 1.4. Add a simple auth check: the gateway includes its `gatewayId` in the URL path. Future enhancement: HMAC-signed connection token.

### Phase 2: Gateway — Outbound tunnel connection

- [ ] Task 2.1. Add a `RelayTunnelClient` to the gateway that connects to `ws://<RELAY_URL>/v1/tunnel/<gatewayId>/connect` on startup.
- [ ] Task 2.2. Wire it into `PrinterService.broadcastState()` — alongside the existing WebSocket fan-out to local clients, also forward the JSON frame to the relay tunnel WebSocket.
- [ ] Task 2.3. Reconnect logic: if the tunnel WebSocket drops, reconnect with exponential backoff (same pattern as MQTT reconnect). Use the existing `RELAY_URL` env var — no new configuration needed.
- [ ] Task 2.4. Log tunnel status at startup: "Relay tunnel: connected to ws://relay:8090/v1/tunnel/<gwId>/connect"

### Phase 3: iOS — LAN-first with relay fallback

- [ ] Task 3.1. Add `relayURL` and `gatewayId` to the `GatewayStreamClient` initializer (sourced from the `Gateway` model's `baseURL` and `gatewayId`).
- [ ] Task 3.2. Update `connect()` to first attempt the LAN WebSocket with a 5-second timeout. On failure, attempt the relay tunnel WebSocket (`wss://<relayURL>/v1/tunnel/<gatewayId>/stream`).
- [ ] Task 3.3. Track the current connection mode: `.lan`, `.relay`, `.disconnected`. Expose it so the `GatewayAdapter` can surface it to the UI.
- [ ] Task 3.4. When `NWPathMonitor` detects a network change to `.satisfied` (Wi-Fi returns), probe the LAN WebSocket in the background. If it succeeds, switch from relay to LAN seamlessly.
- [ ] Task 3.5. Update `GatewayAdapter` to expose the connection mode. Update `AdapterRegistry` to include it in `StateSource` or a new property so the UI can differentiate.

### Phase 4: UI — Connection mode indicators

- [ ] Task 4.1. In `PrinterRowView`, show connection mode:
  - Green dot + "Gateway" — connected via LAN
  - Blue dot + "Remote" — connected via relay tunnel
  - Orange dot + "Push" — offline but receiving push updates
  - Red dot + "Offline" — no connection
- [ ] Task 4.2. In `PrinterDetailView`, update the push fallback banner to also show relay mode: "Connected via relay — remote access through PrintParty relay."
- [ ] Task 4.3. In `GatewayDetailView`, show tunnel status: "Tunnel: connected" or "Tunnel: not available."

## Configuration

### Gateway

No new configuration. Uses existing `RELAY_URL` env var. If `RELAY_URL` is set, the gateway opens both:
- The APNs push forwarding path (existing `POST /v1/push`)
- The tunnel WebSocket (`/v1/tunnel/<gatewayId>/connect`)

### Relay

No new configuration. The tunnel routes are registered alongside existing push routes.

### iOS App

Needs to know the relay URL. Two options:
- **Option A**: Hardcode the project's relay URL (e.g., `wss://relay.printparty.io`). Simplest.
- **Option B**: The gateway returns `relayURL` in the `/healthz` response or the pairing response. More flexible.

Recommend Option B — add `relayURL` to the gateway's health/pairing responses so the iOS app discovers it automatically during pairing.

## Verification Criteria

- Gateway starts, opens tunnel to relay. Relay logs "Tunnel registered: <gatewayId>"
- iOS on LAN: connects directly, green dot, sub-second latency
- iOS off LAN: automatically falls back to relay tunnel within 5s, blue dot, data flows
- iOS returns to LAN: probes LAN, switches back within a few seconds, green dot
- Gateway goes down: relay drops tunnel, iOS clients get close frame → offline or push fallback
- Multiple iOS devices: all receive data through the relay fan-out simultaneously

## Potential Risks and Mitigations

1. **Relay becomes a bottleneck for all data**
   Mitigation: Telemetry frames are small (~1KB JSON). At 1 update/second per printer, a relay handling 1000 gateways with 2 printers each = ~2MB/s. Well within a single VPS.

2. **Relay outage kills remote access**
   Mitigation: LAN access still works. APNs push fallback still works. The relay is a convenience, not a hard dependency.

3. **Security: relay sees plaintext WebSocket frames**
   Mitigation: Same trust model as APNs push — the relay already sees the same data in the push path. E2EE for WebSocket frames is a future enhancement using the same shared key from pairing.

4. **Gateway behind restrictive firewall blocks outbound WebSocket**
   Mitigation: Fall back to the existing APNs-only path. The tunnel is additive.

## Alternative Approaches

1. **TURN/STUN (WebRTC-style)**: Peer-to-peer with relay fallback. Much more complex, overkill for unidirectional telemetry.
2. **HTTP long-polling through relay**: Simpler than WebSocket but higher latency and bandwidth. Not recommended.
3. **gRPC streaming**: Better for production at scale but adds a heavy dependency. WebSocket is simpler and already in use.
