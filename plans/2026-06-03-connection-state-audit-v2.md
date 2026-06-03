# Connection State UI Improvements — iOS Only

## Objective

Improve the PrintParty iOS app's connection state visibility using **only data and signals that already exist on the client side**. No gateway or relay server changes. Focus on surfacing richer, more responsive connection information in the UI by leveraging `GatewayStreamClient.connectionMode`, `MQTTClient.State`, existing `/healthz` responses, and `NWPathMonitor` events.

---

## Data Already Available (No Backend Changes Needed)

| Signal | Source | Currently Used? |
|--------|--------|-----------------|
| `GatewayStreamClient.connectionMode` (`.lan` / `.relay` / `.disconnected`) | `GatewayAdapter.swift:34-36` | Yes, but only to set `StateSource` — not shown on gateway screens |
| `GatewayStreamClient.isConnected` | `GatewayStreamClient.swift:55` | Internal only |
| `GatewayStreamClient.onConnect` / `onDisconnect` callbacks | `GatewayStreamClient.swift:62-66` | Used by `GatewayAdapter` to emit offline state |
| `MQTTClient.State` (`.idle` / `.connecting` / `.connected` / `.disconnected`) | `MQTTClient.swift:29-34` | Drives `BambuLanAdapter` reconnect, but not exposed past the adapter |
| `AdapterRegistry.StateSource` (`.adapter` / `.relay` / `.push`) | `AdapterRegistry.swift:29-36` | Shown in `PrinterRowView` and `PrinterDetailView` |
| `PairingClient.ping(baseURL:)` → `HealthResponse` (status, version, gatewayId) | `PairingClient.swift:71-87` | One-shot on view appear in `GatewayRow` and `GatewayDetailView` |
| `NWPathMonitor` path updates | `GatewayStreamClient.swift:46, 81-86` | Used for reconnect; not shared with UI |
| `PrintJobState.updatedAt` | `PrintJobState.swift:66` | Shown only in debug card |
| `PrintJobState.errorMessage` | `PrintJobState.swift:62` | Used as informal "connecting" state text |
| Gateway `relayURL` | `Gateway.relayURL` persisted in SwiftData | Used to create adapters, but not for relay health checks |
| Gateway `baseURL` | `Gateway.baseURL` persisted in SwiftData | Used for direct health pings only |

---

## Implementation Plan

### Phase 1: Richer Connection Phase Model

**Goal**: Replace the overloaded `offline + errorMessage` pattern with explicit connection phases so the UI can distinguish "connecting" from "disconnected."

- [ ] **1.1 Create a `ConnectionPhase` enum** in `PrintParty/Core/Domain/`. Cases: `.disconnected(reason: String?)`, `.connecting`, `.connectedLAN`, `.connectedRelay`, `.push`. This is a UI-layer type only — it does not touch `PrinterStage` or `PrintJobState` (those are shared wire-format types that the backend work will evolve separately).

- [ ] **1.2 Add `connectionPhases: [UUID: ConnectionPhase]` to `AdapterRegistry`** alongside the existing `states` and `stateSources` dictionaries (`AdapterRegistry.swift:26-37`). This becomes the canonical place views read connection phase from. Remove `stateSources` once all consumers migrate (or keep it as a computed accessor for backward compat).

- [ ] **1.3 Expose connection phase from `GatewayAdapter`**. Add a published `connectionPhase: ConnectionPhase` property that derives from `GatewayStreamClient`'s existing `connectionMode` and `isConnected`. The `onConnect` callback (`GatewayStreamClient.swift:66`) sets `.connectedLAN` or `.connectedRelay` based on `connectionMode`. The `onDisconnect` callback (`GatewayStreamClient.swift:62`) sets `.disconnected`. Add a new `onConnecting` callback fired at the top of `connect()` (`GatewayStreamClient.swift:208`) and `tryRelayOrReconnect()` (`GatewayStreamClient.swift:249`) that sets `.connecting`.

- [ ] **1.4 Expose connection phase from `BambuLanAdapter`**. The `MQTTClient` already has `.idle`, `.connecting`, `.connected`, `.disconnected(reason:)` states (`MQTTClient.swift:29-34`) surfaced via `onStateChange` (`MQTTClient.swift:48`). Map these to `ConnectionPhase` in `BambuLanAdapter.handle(mqttState:)` (`BambuLanAdapter.swift:142`): `.connecting` → `.connecting`, `.connected` → `.connectedLAN`, `.disconnected` → `.disconnected(reason:)`.

- [ ] **1.5 Update the `AdapterRegistry` pump loop** (`AdapterRegistry.swift:63-87`) to read `connectionPhase` from the adapter and write it into `connectionPhases[printerId]`. This requires adding `connectionPhase` to the `PrinterAdapter` protocol or using type-specific casts (current approach at line 71 already casts to `GatewayAdapter`).

- [ ] **1.6 Add foreground recovery to `BambuLanAdapter`**. Observe `UIApplication.willEnterForegroundNotification` (same pattern as `GatewayStreamClient.swift:92-100`). On foreground, if `MQTTClient.State` is `.disconnected`, cancel pending backoff and reconnect immediately. This ensures Bambu LAN printers recover as fast as gateway printers do after app backgrounding.

### Phase 2: Unified Gateway Connection Status

**Goal**: Deduplicate the `ConnectionStatus` enum and enrich it with relay reachability using only existing client-side data.

- [ ] **2.1 Extract a shared `GatewayConnectionStatus` enum** into `PrintParty/Core/Domain/`. Cases: `.unknown`, `.checking`, `.lanOnline(version: String)`, `.lanOfflineRelayOnline`, `.lanOfflineRelayUnknown`, `.offline(reason: String)`. This replaces the identical private enums in `SettingsView.swift:158-163` and `GatewayDetailView.swift:29-31`.

- [ ] **2.2 Implement a relay reachability check using the existing WebSocket probe pattern**. After the direct `/healthz` ping fails, if the gateway has a `relayURL`, attempt a lightweight WebSocket connection to `ws://{relayURL}/v1/tunnel/{gatewayId}/stream` with a 5-second timeout (same pattern as `GatewayStreamClient.probeLANInBackground()` at `GatewayStreamClient.swift:324-381`). If a single frame arrives, the relay path is alive → `.lanOfflineRelayOnline`. If it times out → `.offline`. This uses only existing relay infrastructure, no new endpoints needed.

- [ ] **2.3 Cross-reference adapter connection data for gateway health**. When the `GatewayRow` / `GatewayDetailView` checks health, also look at `AdapterRegistry.connectionPhases` for any printer on that gateway. If any printer has `.connectedLAN` or `.connectedRelay`, the gateway is clearly reachable via that path — no HTTP ping needed. This makes health status reflect the live WebSocket state rather than a one-shot HTTP probe.

- [ ] **2.4 Update `GatewayRow`** (`SettingsView.swift:155-268`) to use `GatewayConnectionStatus` and show relay reachability. Visual treatment:
  - **LAN online**: Green dot, version badge (unchanged)
  - **LAN offline, relay online**: Blue dot, "Via Relay" badge, `globe` icon
  - **Both offline**: Red dot, error reason (unchanged)
  - **Checking**: Gray dot + spinner (unchanged)

- [ ] **2.5 Update `GatewayDetailView` gateway info section** (`GatewayDetailView.swift:82-105`). Add a second `LabeledContent("Relay")` row that shows relay reachability as a separate indicator. If no `relayURL` is configured, show "Not configured" in muted text. If configured, show "Reachable" (blue) or "Unreachable" (red).

### Phase 3: Event-Driven Gateway Health Monitor

**Goal**: Replace one-shot health checks with a persistent, `@Observable` monitor that reacts to network changes and app lifecycle, so gateway status is always fresh.

- [ ] **3.1 Create `GatewayHealthMonitor`** (new file `PrintParty/Core/Net/GatewayHealthMonitor.swift`). An `@Observable`, `@MainActor` singleton that:
  - Holds `statuses: [String: GatewayConnectionStatus]` keyed by `gatewayId`
  - On `start(gateways:)`, pings each gateway via `PairingClient.ping()` and (if needed) attempts relay WebSocket probe
  - Observes `NWPathMonitor` — on network status changes (satisfied ↔ unsatisfied), re-checks all gateways immediately
  - Observes `UIApplication.willEnterForegroundNotification` — re-checks all gateways on foreground return
  - Re-checks on a 60-second interval when the app is foregrounded (pause on background)
  - Cross-references `AdapterRegistry.connectionPhases` as a fast-path: if an adapter for a printer on this gateway is already `.connectedLAN`, skip the HTTP ping and mark `.lanOnline`

- [ ] **3.2 Register `GatewayHealthMonitor.shared`** in `PrintPartyApp.swift` alongside the existing singletons (line 13-17). Feed it gateways on launch from `PrintersListView.syncGatewayURLs()` or a dedicated init path.

- [ ] **3.3 Wire `GatewayRow` to read from `GatewayHealthMonitor`** instead of running its own `.task { await checkHealth() }` (`SettingsView.swift:191`). The row becomes purely declarative — it reads the observable status and re-renders on changes. Remove the local `@State private var status` and `checkHealth()` method.

- [ ] **3.4 Wire `GatewayDetailView` the same way** (`GatewayDetailView.swift:60-62`). Remove the local `connectionStatus` state and `checkHealth()` method. Read from `GatewayHealthMonitor.shared.statuses[gateway.gatewayId]`.

### Phase 4: Printer Row & Detail UI Enhancements

**Goal**: Use the new `ConnectionPhase` to show richer, more honest connection indicators.

- [ ] **4.1 Update `PrinterRowView.connectionDot`** (`PrinterRowView.swift:54-65`). Replace the static `Circle()` with a phase-aware indicator:
  - `.connecting`: Pulsing/breathing gray or yellow dot (use a simple `opacity` animation with `.repeatForever`)
  - `.connectedLAN`: Solid green dot (same as today's adapter+online)
  - `.connectedRelay`: Solid blue dot (same as today's relay)
  - `.push`: Solid orange dot (same as today)
  - `.disconnected`: Solid red dot (same as today's adapter+offline)

- [ ] **4.2 Update `PrinterRowView.connectionLabel`** (`PrinterRowView.swift:76-99`). Map from `ConnectionPhase`:
  - `.connecting` → `Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")` in gray
  - `.connectedLAN` → "LAN" or "Gateway" label depending on `adapterKind` (existing behavior)
  - `.connectedRelay` → "Remote" with globe icon (existing behavior)
  - `.push` → "Push" with antenna icon (existing behavior)
  - `.disconnected` → `Label("Offline", systemImage: "wifi.slash")` in red

- [ ] **4.3 Surface `updatedAt` freshness in `PrinterRowView`** when phase is `.push` or `.disconnected`. Show a relative timestamp like "2m ago" next to the connection label. Currently this info is only in the debug card (`PrinterDetailView.swift:328-329`). Use `RelativeDateTimeFormatter` for concise output.

- [ ] **4.4 Update `PrinterDetailView` banners** (`PrinterDetailView.swift:33-37`). Add a `.connecting` banner with a `ProgressView` spinner: "Connecting to gateway..." or "Connecting to printer..." depending on adapter kind. Currently when connecting, the detail view shows nothing (no banner) because `source` is `.adapter` and `stage` is `.offline`, which falls through without any banner.

- [ ] **4.5 Add a `.disconnected` banner to `PrinterDetailView`**. When `ConnectionPhase` is `.disconnected(reason:)`, show a red banner with the reason text and the last update time. Currently the "offline" state relies on the user noticing the red stage icon — there's no prominent explanation.

- [ ] **4.6 Enhance the debug card** (`PrinterDetailView.swift:303-338`). Add `ConnectionPhase` as an explicit row (replacing the derived "Source" row). Add the current reconnect backoff delay if available (this would require exposing `reconnectAttempt` from the adapters — optional stretch goal).

### Phase 5: Aggregate Status Banner on Printer List

**Goal**: Give users an at-a-glance summary at the top of the printer list.

- [ ] **5.1 Add a `ConnectionSummaryBanner` view** to `PrintersListView` (`PrintersListView.swift:82-93`), inserted above the `ForEach` printer list. The banner reads from `AdapterRegistry.connectionPhases` and `GatewayHealthMonitor.statuses` to summarize:
  - **All green** (every printer `.connectedLAN`): No banner shown, or a minimal "All connected" that auto-hides after 3 seconds
  - **Some via relay**: Blue banner — "N printer(s) connected via relay"
  - **Some via push**: Orange banner — "N printer(s) showing push data"  
  - **Some disconnected**: Red banner — "N printer(s) offline"
  - **Mixed**: Show the most severe condition with count

- [ ] **5.2 Make the banner tappable** to scroll to the first affected printer, or show a brief popover listing which printers are in each state. Keep it lightweight — a `DisclosureGroup` or a `.popover` with a mini list.

---

## Verification Criteria

- Printer rows show a pulsing dot and "Connecting..." label during initial connection and reconnect backoff, instead of a static red "Offline" dot
- Gateway rows in Settings show distinct LAN vs relay reachability (green for LAN, blue for relay-only, red for both offline)
- Gateway detail view shows separate LAN and relay status rows
- Gateway health updates within 2-3 seconds of network changes (Wi-Fi toggle, foreground return) without manual navigation
- Navigating away from Settings and back does not re-trigger health checks — the persistent monitor provides current state
- Push-sourced data shows relative age ("2m ago") in the printer list row, not just in the detail debug card
- `BambuLanAdapter` reconnects promptly on foreground return (within 1-2 seconds, not waiting for backoff timer)
- Printer detail view shows contextual banners for all connection phases: connecting (spinner), relay (blue), push (orange), disconnected (red with reason)

---

## Potential Risks and Mitigations

1. **`ConnectionPhase` must stay in sync with adapter state**
   Mitigation: Derive `ConnectionPhase` from existing callbacks (`onConnect`, `onDisconnect`, `onStateChange`) that already fire reliably. The new `onConnecting` callback is the only addition, and it fires at the top of methods that already exist. No new async coordination needed.

2. **Relay probe WebSocket creates a brief extra connection**
   Mitigation: The probe uses the same 5-second-timeout pattern already proven in `GatewayStreamClient.probeLANInBackground()` (`GatewayStreamClient.swift:324-381`). It opens, waits for one frame, then closes. Only triggered when the direct ping fails and the user is on the gateway screen or when the 60s monitor interval fires.

3. **`GatewayHealthMonitor` 60s timer battery impact**
   Mitigation: Timer is paused when the app enters background. When foregrounded, a single immediate check runs, then the 60s cadence resumes. The HTTP ping (`PairingClient.ping`) has a 5s timeout — worst case is 5s of network activity per gateway per minute. For 1-2 gateways this is negligible.

4. **Animation performance for pulsing connection dots**
   Mitigation: Use a simple SwiftUI `.opacity` animation with `.repeatForever(autoreverses: true)` on the `Circle()` — this is GPU-composited and costs effectively nothing. No custom `CAAnimation` or timers.

5. **`PrinterAdapter` protocol change for `connectionPhase`**
   Mitigation: The protocol lives in `Shared/Adapters/PrinterAdapter.swift`. Adding an optional `connectionPhase` property (with default `.disconnected`) maintains backward compatibility with the widget extension target if it conforms to the protocol. Alternatively, keep the cast-to-concrete-type approach already used at `AdapterRegistry.swift:71`.

---

## Out of Scope (Deferred to Backend Work)

- Gateway WebSocket message envelope / bidirectional protocol (in progress)
- Relay-side initial snapshot cache
- `printerAdded` / `printerRemoved` WebSocket events
- Gateway-level health events over WebSocket
- New relay endpoints (`/v1/tunnel/{id}/status`)

These will be addressed when the encrypted bidirectional WebSocket work lands on the gateway and relay.

---

## Recommended Implementation Order

| Order | Task | Rationale |
|-------|------|-----------|
| 1 | Phase 1 (ConnectionPhase model + adapter wiring) | Foundation — everything else reads from this |
| 2 | Phase 4.1-4.2 (Printer row dot + label) | Immediate visible payoff using the new model |
| 3 | Phase 1.6 (BambuLan foreground recovery) | Quick win — one `NotificationCenter` observer |
| 4 | Phase 2.1-2.2 (GatewayConnectionStatus + relay probe) | Gateway screen enrichment |
| 5 | Phase 3 (GatewayHealthMonitor) | Replaces stale one-shot checks |
| 6 | Phase 2.3-2.5 (Gateway UI wiring) | Consumes the monitor |
| 7 | Phase 4.3-4.6 (Printer detail banners + freshness) | Detail screen polish |
| 8 | Phase 5 (Aggregate banner) | Final polish layer |
