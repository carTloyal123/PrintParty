# Connection State Visibility & Event-Driven Architecture Audit

## Objective

Surface richer, real-time connection state throughout the PrintParty iOS app so users always know *how* they are connected (LAN, relay, push, disconnected) to both gateways and printers, and migrate from one-shot HTTP polling to event-driven updates where feasible.

---

## Current State Assessment

### What Works Well
- **Printer rows** already show a colored dot + label for LAN / Remote / Push (`PrinterRowView.swift:55-99`)
- **Printer detail** shows relay and push banners with contextual messaging (`PrinterDetailView.swift:55-87`)
- **WebSocket stream** is fully event-driven: `GatewayStreamClient` yields `PrintJobState` via `AsyncStream`, pumped into `@Observable AdapterRegistry.states` — SwiftUI re-renders instantly on change
- **Three-tier fallback** (LAN WS → Relay WS → APNs Push) degrades gracefully

### Gaps Identified

| # | Gap | Location | Impact |
|---|-----|----------|--------|
| G1 | **Gateway row only shows direct HTTP health (online/offline)** — no relay reachability indicator | `SettingsView.swift:155-268` | User can't tell if remote access is working when off LAN |
| G2 | **Gateway health check is one-shot on view appear** — no periodic refresh, no event-driven update | `SettingsView.swift:191`, `GatewayDetailView.swift:61` | Status goes stale if network changes while view is on-screen |
| G3 | **No "connecting" stage exposed to UI** — `PrinterStage.offline` is used for both "not yet connected" and "lost connection", with the only distinction buried in `errorMessage` strings | `GatewayAdapter.swift:58-59`, `BambuLanAdapter.swift:127-128`, `BambuLanAdapter.swift:150-153` | User sees "Offline" when the adapter is actively trying to connect |
| G4 | **Duplicated `ConnectionStatus` enum** in two views with identical shape | `SettingsView.swift:158-163`, `GatewayDetailView.swift:29-31` | Code duplication; any enhancement must be made in two places |
| G5 | **No gateway-level events on the WebSocket** — the stream only sends `PrintJobState` frames, no "printer added/removed" or "gateway health" events | `gateway/.../StreamRoutes.swift`, `gateway/.../PrinterService.swift:312-333` | iOS client doesn't know when printers are added/removed from gateway without manual refresh |
| G6 | **Relay tunnel has no initial snapshot** — direct `/v1/stream` sends all current states on connect, but the relay fan-out in `TunnelBroker.forward()` only forwards frames as they arrive | `relay/.../TunnelRoutes.swift:86-110` vs `gateway/.../PrinterService.swift:298-304` | Client connecting via relay must wait for the next telemetry cycle to get state |
| G7 | **`GatewayDetailView` printer list is HTTP-only** — fetched via `GET /v1/printers` with no real-time updates | `GatewayDetailView.swift:257-278` | Printer list doesn't update as printers come online/offline unless user pull-to-refreshes |
| G8 | **`AdapterRegistry.StateSource` doesn't distinguish "connecting" from "connected"** — `.adapter` means both "live LAN connection" and "adapter exists but is in backoff reconnect" | `AdapterRegistry.swift:29-36` | Green dot can show while adapter is actually in reconnect backoff |
| G9 | **No aggregate connection health indicator** — no single place in the UI that summarizes "all systems nominal" vs "degraded" | Entire app | User must drill into each gateway and each printer to understand overall health |
| G10 | **BambuLanAdapter has no foreground recovery** — unlike `GatewayStreamClient`, the MQTT adapter doesn't reconnect on `willEnterForeground` | `BambuLanAdapter.swift` (no foreground observer) | After backgrounding the app, Bambu LAN printers may stay "offline" until the backoff timer fires |

---

## Implementation Plan

### Phase 1: Enrich the Connection State Model

- [ ] **1.1 Introduce a unified `ConnectionPhase` enum** in `Shared/Domain/` (or `PrintParty/Core/Domain/`) to replace the implicit "offline + errorMessage" pattern. Recommended cases: `.disconnected(reason: String)`, `.connecting`, `.connectedLAN`, `.connectedRelay`, `.push`. This replaces the current overloading of `PrinterStage.offline` for connection semantics.

- [ ] **1.2 Extend `AdapterRegistry.StateSource`** (currently at `AdapterRegistry.swift:29-36`) to include a `.connecting` case, or replace it entirely with the new `ConnectionPhase`. This allows the UI to distinguish "actively reconnecting" from "dead." The pump loop at `AdapterRegistry.swift:63-87` would set the phase based on `GatewayStreamClient.connectionMode` and `MQTTClient.State`.

- [ ] **1.3 Add an `onConnecting` callback to `GatewayStreamClient`** alongside the existing `onConnect` / `onDisconnect` (`GatewayStreamClient.swift:62-66`). Fire it at the start of `connect()` (line 208) and `tryRelayOrReconnect()` (line 249) so the adapter can emit a "connecting" state to the UI immediately rather than staying on stale "offline" text.

- [ ] **1.4 Add foreground recovery to `BambuLanAdapter`** mirroring the pattern in `GatewayStreamClient.swift:92-100`. Observe `UIApplication.willEnterForegroundNotification`, and if the MQTT client is disconnected, cancel any pending backoff and reconnect immediately. This closes gap G10.

- [ ] **1.5 Deduplicate `ConnectionStatus`** (G4). Extract the shared `ConnectionStatus` enum from `SettingsView.swift:158-163` and `GatewayDetailView.swift:29-31` into a standalone type (e.g., `GatewayConnectionStatus`) in `PrintParty/Core/Domain/`. Add a new `.relayReachable` case to express "can't reach gateway directly but relay works."

### Phase 2: Surface Relay Status on Gateway Screens

- [ ] **2.1 Add relay health check to `GatewayRow`** (`SettingsView.swift:249-268`). After the direct `/healthz` ping, if the direct check fails *and* the gateway has a `relayURL`, perform a secondary check through the relay (e.g., `GET {relayURL}/v1/tunnel/{gatewayId}/healthz` or attempt a WebSocket handshake). Display a distinct visual state: yellow/blue dot with "Relay" label, similar to how `PrinterRowView` shows "Remote" in blue.

- [ ] **2.2 Add relay status to `GatewayDetailView`** (`GatewayDetailView.swift:82-105`). Expand the gateway info section to show three-state connectivity: "LAN: Online / Relay: Online", "LAN: Offline / Relay: Online", "Both: Offline". This could be a pair of `LabeledContent` rows or a compact multi-dot indicator.

- [ ] **2.3 Add a relay health endpoint to the relay server** if one doesn't exist. Currently the relay has no equivalent of `/healthz` that checks whether a specific gateway tunnel is active. Add `GET /v1/tunnel/{gatewayId}/status` to `relay/.../TunnelRoutes.swift` that returns whether an upstream WebSocket exists for that gateway in the `TunnelBroker._upstreams` map. This gives the iOS client a lightweight way to check relay reachability without opening a full WebSocket.

### Phase 3: Move Gateway Health to Event-Driven Updates

- [ ] **3.1 Replace one-shot gateway health checks with a persistent monitor**. Create a `GatewayHealthMonitor` (new file in `PrintParty/Core/Net/`) that:
  - Maintains a lightweight WebSocket or periodic ping (every 30s) to each paired gateway's `/healthz`
  - Also checks relay reachability on the same cadence
  - Publishes state via `@Observable` so all views react instantly
  - Listens to `NWPathMonitor` and `willEnterForegroundNotification` to trigger immediate re-checks (same pattern as `GatewayStreamClient.swift:80-100`)
  - Replaces the `.task { await checkHealth() }` calls in both `GatewayRow` (`SettingsView.swift:191`) and `GatewayDetailView` (`GatewayDetailView.swift:61`)

- [ ] **3.2 Register `GatewayHealthMonitor` as a singleton** alongside `AdapterRegistry.shared` in `PrintPartyApp.swift`. Feed it the list of gateways from SwiftData on launch and when gateways are added/removed.

- [ ] **3.3 Wire `GatewayRow` and `GatewayDetailView` to read from `GatewayHealthMonitor`** instead of performing their own async health checks. Views become purely declarative — they read from the observable monitor and re-render on state changes.

### Phase 4: Introduce Gateway-Level WebSocket Events

- [ ] **4.1 Define a message envelope for the gateway WebSocket stream**. Currently every frame is a raw `PrintJobState` JSON (`gateway/.../PrinterService.swift:312-333`). Wrap messages in an envelope like `{ "type": "printerState", "payload": {...} }` so new event types can be added. Maintain backward compatibility by having the iOS client accept both bare `PrintJobState` and enveloped messages during a transition period.

- [ ] **4.2 Add a `gatewayStatus` event type** that the gateway periodically emits (or emits on state change). Include: gateway version, uptime, number of connected printers, relay tunnel status (connected/disconnected), and a list of printer IDs with their MQTT connection states. This lets the iOS client know about gateway health without HTTP polling.

- [ ] **4.3 Add `printerAdded` / `printerRemoved` event types** so that when a printer is registered or deleted on the gateway (via REST API or another iOS client), all connected WebSocket clients are notified. This closes gap G5 and makes `GatewayDetailView`'s printer list update in real time.

- [ ] **4.4 Update `GatewayStreamClient.handleMessage()`** (`GatewayStreamClient.swift:401-418`) to parse the envelope and dispatch to different handlers. `PrintJobState` messages continue to flow through `continuations`; new event types get their own callback or `AsyncStream`.

- [ ] **4.5 Forward gateway-level events through the relay tunnel**. Ensure `RelayTunnelClient` (`gateway/.../RelayTunnelClient.swift`) and `TunnelBroker` (`relay/.../TunnelRoutes.swift`) forward all text frames regardless of type, since they already do — but add integration tests to confirm non-`PrintJobState` frames survive the relay path.

### Phase 5: Fix Relay Tunnel Initial Snapshot (G6)

- [ ] **5.1 Implement "snapshot on connect" for relay tunnel clients**. When a downstream iOS client connects to `/v1/tunnel/{gatewayId}/stream`, the relay should either:
  - **(Option A)** Forward a `requestSnapshot` frame upstream to the gateway, which responds with current state for all printers. Requires bidirectional messaging on the tunnel.
  - **(Option B — simpler)** Have the `TunnelBroker` cache the last frame per printer (keyed by `printerId` extracted from JSON). On new downstream connect, replay cached frames. This mirrors what the gateway does at `PrinterService.swift:298-304` but at the relay layer.

  Recommendation: **Option B** — it's stateless from the gateway's perspective and doesn't require protocol changes.

- [ ] **5.2 Implement the relay-side cache** in `TunnelBroker` (`relay/.../TunnelRoutes.swift`). When forwarding frames from upstream, parse the `printerId` field and store the latest frame in a `[String: [String: String]]` map (gatewayId → printerId → last JSON frame). On downstream connect, replay all cached frames for that gateway.

### Phase 6: Aggregate Health Dashboard

- [ ] **6.1 Add a connection summary banner to `PrintersListView`**. At the top of the printer list, show a compact banner that aggregates health across all gateways and printers. Examples:
  - All green: "All systems connected" (hidden or minimal)
  - Partial: "2 printers connected via relay" (blue banner)
  - Degraded: "Gateway offline — showing push data" (orange banner)
  - Derive from `GatewayHealthMonitor` + `AdapterRegistry.stateSources`

- [ ] **6.2 Add a "connecting" state indicator to `PrinterRowView`**. When `ConnectionPhase` is `.connecting`, show a pulsing or animated dot instead of a static colored circle, and change the label to "Connecting..." This replaces the current behavior where the row shows a red "Offline" dot during initial connection (`PrinterRowView.swift:67-72`).

- [ ] **6.3 Surface `updatedAt` age in `PrinterRowView`** for push-delivered data. When the state source is `.push`, show a relative timestamp ("2m ago") next to the connection label so the user understands data freshness. Currently this is only visible in the debug card (`PrinterDetailView.swift:328-329`).

---

## Verification Criteria

- Gateway rows in Settings show distinct indicators for LAN-reachable, relay-reachable, and fully-offline states
- Gateway detail view displays both LAN and relay connectivity status simultaneously
- Printer rows show an animated "connecting" indicator during initial connection and reconnect backoff, not a static red "Offline" dot
- Connection state updates arrive within 1-2 seconds of network changes (foreground recovery, Wi-Fi toggle) without requiring manual refresh
- Gateway health is maintained by a persistent monitor — navigating away from Settings and back does not trigger a new HTTP health check
- Printers added or removed on the gateway appear/disappear in `GatewayDetailView` without pull-to-refresh (after Phase 4)
- Relay-connected iOS clients receive full printer state immediately on WebSocket connect (after Phase 5)
- Push-delivered data shows age/staleness in the printer list, not just on the detail screen

---

## Potential Risks and Mitigations

1. **Breaking the WebSocket protocol (Phase 4)**
   Mitigation: Implement a transition period where the iOS client accepts both bare `PrintJobState` and enveloped messages. Gate envelope sending behind a gateway version check (the iOS client already receives `version` from `/healthz`). Roll out the gateway update first, then the iOS update.

2. **Relay-side caching adds state to a stateless service (Phase 5)**
   Mitigation: Keep the cache in-memory only, bounded per gateway (e.g., max 50 printers), with a TTL of 5 minutes. On upstream disconnect, clear the cache for that gateway. This is a "best effort" optimization, not a correctness requirement.

3. **`GatewayHealthMonitor` battery/network overhead (Phase 3)**
   Mitigation: Use a conservative 30-second interval. Pause monitoring when the app is backgrounded (cancel the timer in `didEnterBackground`, restart in `willEnterForeground`). Use `NWPathMonitor` to skip checks when the network is unsatisfied.

4. **Multiple `GatewayAdapter` instances sharing one `GatewayStreamClient` per gateway**
   Currently each `GatewayAdapter` creates its own `GatewayStreamClient` (`GatewayAdapter.swift:80-84`), meaning two printers on the same gateway open two WebSocket connections. This isn't directly related to the connection visibility work but will interact with the `GatewayHealthMonitor` — the health monitor should not duplicate connections. Consider deduplicating stream clients per gateway in a follow-up.

5. **`ConnectionPhase` enum proliferation**
   Mitigation: Keep `ConnectionPhase` as the single source of truth for "how is this printer/gateway connected right now." Deprecate the separate `StateSource` enum and the implicit `offline + errorMessage` pattern. Migrate all consumers in one pass to avoid inconsistency.

---

## Alternative Approaches

1. **Server-Sent Events (SSE) instead of WebSocket for health** — Lower overhead for unidirectional health updates, but the entire stack is already WebSocket-based. Adding SSE introduces a second real-time transport to maintain. Not recommended.

2. **Combine/Publisher-based observation instead of `@Observable`** — The app already uses the modern Observation framework effectively. Switching to Combine would add complexity without benefit. Not recommended.

3. **Push-based gateway health via APNs** — The gateway could push health status changes through the relay → APNs path. This would work even when the app is backgrounded, but adds complexity to the push payload schema and doesn't help with the foreground experience where WebSocket is available. Could be a future enhancement for background health alerts.

---

## Priority Ordering

| Priority | Phase | Rationale |
|----------|-------|-----------|
| **P0** | Phase 1 (Connection State Model) | Foundation for all other work; fixes the "offline vs connecting" confusion |
| **P0** | Phase 2 (Relay Status on Gateway) | Directly addresses the user's primary complaint — gateway screen doesn't show relay access |
| **P1** | Phase 3 (Event-Driven Health) | Eliminates stale data; improves perceived responsiveness |
| **P1** | Phase 5 (Relay Initial Snapshot) | Fixes a real UX gap where relay clients see no data until next telemetry cycle |
| **P2** | Phase 4 (Gateway WebSocket Events) | Requires gateway + relay + iOS changes; higher coordination cost |
| **P2** | Phase 6 (Aggregate Dashboard) | Polish; can be done incrementally after the foundation is solid |
