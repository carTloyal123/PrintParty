# PrintParty Data Pipeline Improvements

## Objective

Fix two user-facing bugs (push fallback not reaching the main UI; WebSocket not reconnecting after returning to home Wi-Fi) and restructure the data pipeline so that all state sources (adapter streams, APNs push, future protocols) merge through a single unified store. The result: the UI always shows the freshest state regardless of delivery path, the push fallback becomes automatic rather than a special case, and adding new printer protocols requires zero changes to the state management layer.

---

## Root Cause Analysis

### Bug 1 — Push Fallback Never Reaches the Main UI

**Root cause: the pump task is blocked on `for await` and never re-evaluates push state.**

The `AdapterRegistry` pump task (`AdapterRegistry.swift:64-87`) is a `for await newState in stream` loop. When the gateway WebSocket disconnects, `GatewayStreamClient` stops yielding values, so the `GatewayAdapter` emits exactly one `.offline` state and then the stream goes silent. At that single moment, the pump checks `LiveActivityCoordinator.shared.pushState(for:)` — but the APNs push has likely not arrived yet (it's asynchronous and may come seconds or minutes later).

Once that check passes, the pump blocks indefinitely waiting for the next adapter value. When `pushDeliveredStates` is eventually updated by the `contentUpdates` observer in `LiveActivityCoordinator.swift:381-396`, **nothing re-evaluates the fallback condition**. The `pushDeliveredStates` dictionary is `@Observable`, but no SwiftUI view or `withObservationTracking` closure reads it in a way that feeds back into `AdapterRegistry.states`.

The UI reads `registry.states[printer.id]` and `registry.stateSources[printer.id]` — both stuck at the last adapter-emitted value (`.offline` / `.adapter`). The push fallback banner in `PrinterDetailView.swift:34` checks `source == .push`, which is never set because the pump never runs the fallback path again.

**Timeline of failure:**
1. WebSocket disconnects → adapter yields `.offline`
2. Pump receives `.offline`, checks `pushState(for:)` → `nil` (no push yet) → stores `.offline` with `.adapter` source
3. Pump blocks on `for await` — no more adapter values coming
4. Push arrives → `pushDeliveredStates[id]` updated → no one re-checks
5. UI stays frozen showing `.offline` / `.adapter`

### Bug 2 — WebSocket Reconnection Stalls

**Root cause: no network-change trigger; reconnect timing drifts badly on cellular.**

The reconnect logic in `GatewayStreamClient.swift:120-130` does keep looping (it never stops trying), but has two compounding problems:

1. **No `NWPathMonitor`**: When the phone leaves Wi-Fi, every reconnect attempt to a LAN IP (e.g. `192.168.x.x`) either fails immediately or hangs for `URLSession`'s default TCP timeout (~60s). There's no listener to detect "Wi-Fi is back" and immediately trigger a connect. The user must wait for the next scheduled attempt after rejoining Wi-Fi — up to 60 seconds at max backoff.

2. **TCP timeout stacking**: Each failed connection attempt on cellular may consume the full TCP timeout before calling the failure handler. During that hang, the `Task.sleep` hasn't started yet. So the effective cycle time is `TCP_timeout + backoff_delay`, potentially 2+ minutes between usable reconnect attempts. When the user returns to Wi-Fi, they may be mid-sleep or mid-hang, causing perceived "permanent" disconnection.

3. **Backoff never resets until success**: `reconnectAttempt` resets to 0 only on a successful `receive` (`GatewayStreamClient.swift:86`). After 6+ failures on cellular, every subsequent attempt uses the 60s cap, even the first one after Wi-Fi returns.

### Architecture Gap — Tightly Coupled Pipeline

The current design has the `AdapterRegistry` pump task as the sole entry point for state into the `states` dictionary. Push-delivered state is a bolt-on check inside that same loop. This means:
- Push state can only be used when the pump happens to iterate
- Adding a new data source (e.g. REST polling, Bluetooth) requires modifying the pump logic
- The `StateSource` enum is checked at adapter-event time, not at state-arrival time

---

## Implementation Plan

### Phase 1 — Fix Push Fallback (Bug 1)

**Strategy**: Make `LiveActivityCoordinator.pushDeliveredStates` changes actively push into `AdapterRegistry.states`, rather than waiting for the adapter pump to re-check.

- [ ] **1.1. Add a `ingestPushState(_:for:)` method to `AdapterRegistry`.**
  This method accepts a `PrintJobState` and a `printerId`, checks whether the current adapter source is offline, and if so writes the push state into `states[printerId]` and sets `stateSources[printerId] = .push`. This gives the push path a direct write channel into the observable store.
  - File: `PrintParty/Core/Adapters/AdapterRegistry.swift`
  - Add method signature: `func ingestPushState(_ state: PrintJobState, for printerId: UUID)`
  - Logic: look up the local printer ID (handle remote→local mapping for gateway printers), check if the current adapter is offline (either `states[localId]?.stage == .offline` or adapter not connected), and if so replace the state and source.
  - Rationale: this decouples push state injection from the adapter pump loop.

- [ ] **1.2. Call `ingestPushState` from `LiveActivityCoordinator.observeContentState`.**
  Inside the `for await content in activity.contentUpdates` loop (`LiveActivityCoordinator.swift:387-393`), after updating `pushDeliveredStates`, also call `AdapterRegistry.shared.ingestPushState(state, for: printerId)`.
  - File: `PrintParty/Core/LiveActivity/LiveActivityCoordinator.swift`
  - Modify the `observeContentState` method (around line 387-393).
  - Rationale: every push-delivered state immediately flows into the UI-facing store, triggering SwiftUI re-renders.

- [ ] **1.3. Ensure the adapter pump resets `stateSource` back to `.adapter` when the WebSocket reconnects.**
  In the existing pump task (`AdapterRegistry.swift:64-87`), when `newState.stage != .offline` (i.e. the adapter is back online with real data), always set `stateSources[printerId] = .adapter`. This is already the default path but verify it clears `.push` correctly.
  - File: `PrintParty/Core/Adapters/AdapterRegistry.swift`
  - Verify the `else` branch at line 78-79 unconditionally sets `.adapter`.
  - Rationale: when the WebSocket reconnects, the UI must switch back from the orange push banner to green.

- [ ] **1.4. Add staleness guard to `ingestPushState`.**
  Only accept the push state if `state.updatedAt > states[localId]?.updatedAt`. This prevents a delayed push from overwriting a fresher adapter state if the WebSocket reconnected in the meantime.
  - File: `PrintParty/Core/Adapters/AdapterRegistry.swift`
  - Rationale: prevents temporal ordering bugs in the race between push arrival and WebSocket reconnection.

### Phase 2 — Fix WebSocket Reconnection (Bug 2)

**Strategy**: Add a `NWPathMonitor` to detect network transitions and immediately trigger reconnection, plus add a short TCP timeout to prevent connection attempts from hanging.

- [ ] **2.1. Add a `NetworkMonitor` utility class using `NWPathMonitor`.**
  Create a small `@MainActor` class that wraps `NWPathMonitor`, publishes a boolean `isConnected` and an `AsyncStream<Bool>` of connectivity changes. This will be shared across the app.
  - New file: `PrintParty/Core/Net/NetworkMonitor.swift`
  - Expose: `static let shared`, `var isConnected: Bool`, `func pathUpdates() -> AsyncStream<NWPath.Status>`
  - Rationale: centralizes network state observation; useful beyond just WebSocket reconnect.

- [ ] **2.2. Integrate `NetworkMonitor` into `GatewayStreamClient`.**
  On `start()`, subscribe to `NetworkMonitor.shared.pathUpdates()`. When connectivity transitions from unsatisfied → satisfied, immediately cancel any pending reconnect sleep and call `connect()` with `reconnectAttempt` reset to 0.
  - File: `PrintParty/Core/Net/GatewayStreamClient.swift`
  - Add a `networkTask: Task<Void, Never>?` that listens for path changes.
  - Cancel it in `stop()`.
  - Rationale: eliminates the 60s worst-case delay when returning to Wi-Fi.

- [ ] **2.3. Set a short TCP connection timeout on the `URLSession` used for WebSocket.**
  Configure the `URLSessionConfiguration` with `timeoutIntervalForResource = 10` (or similar short value) so that connection attempts to unreachable LAN IPs fail fast instead of hanging for 60+ seconds.
  - File: `PrintParty/Core/Net/GatewayStreamClient.swift`
  - Modify the `init` to use a configured `URLSessionConfiguration` instead of `.default`.
  - Rationale: prevents reconnect cycles from stacking TCP timeouts, making backoff timing predictable.

- [ ] **2.4. Reset `reconnectAttempt` on network path change.**
  When `NetworkMonitor` reports a new satisfactory path, reset `reconnectAttempt = 0` in `GatewayStreamClient` so the first reconnect on the new network uses minimal delay (2s) rather than the stale 60s cap.
  - File: `PrintParty/Core/Net/GatewayStreamClient.swift`
  - Rationale: the backoff counter reflects failures on the previous network; a new network deserves a fresh start.

- [ ] **2.5. Emit an `.offline` state from `GatewayStreamClient` when the network path becomes unsatisfied.**
  When `NetworkMonitor` reports loss of connectivity, proactively yield an `.offline` state to all continuations and cancel the current `URLSessionWebSocketTask`. This provides immediate UI feedback rather than waiting for the next receive to fail.
  - File: `PrintParty/Core/Net/GatewayStreamClient.swift`
  - Rationale: the UI shows "offline" instantly on network loss rather than after a TCP timeout.

### Phase 3 — Unified Data Pipeline Architecture

**Strategy**: Introduce a `StateStore` that is the single write point for all `PrintJobState` updates. Adapters, push notifications, and future sources all call the same `ingest` method. The `AdapterRegistry` becomes a lifecycle manager for adapters but no longer owns the state dictionary.

- [ ] **3.1. Extract `StateStore` from `AdapterRegistry`.**
  Create a new `@MainActor @Observable` class `StateStore` that owns:
  - `states: [UUID: PrintJobState]` (moved from `AdapterRegistry`)
  - `stateSources: [UUID: StateSource]` (moved from `AdapterRegistry`)
  - `func ingest(_ state: PrintJobState, from source: StateSource, localPrinterId: UUID)`
  - The ingest method applies the staleness guard (only accept if `updatedAt` is newer or source priority is higher) and writes to both dictionaries.
  - New file: `PrintParty/Core/State/StateStore.swift`
  - Rationale: separates "where state lives" from "how adapters are managed". Any source can call `ingest` without going through the adapter pump.

- [ ] **3.2. Define `StateSource` priority ordering.**
  Extend `StateSource` with a priority: `.adapter` > `.push` > `.cached`. When two updates arrive at the same `updatedAt`, prefer the higher-priority source. Add a `.cached` case for future offline-first support.
  - File: `PrintParty/Core/State/StateStore.swift` (move `StateSource` here)
  - Rationale: formalizes the merge strategy so the store can make correct decisions without caller coordination.

- [ ] **3.3. Refactor `AdapterRegistry` pump tasks to write to `StateStore`.**
  Change the `for await newState in stream` loop to call `StateStore.shared.ingest(newState, from: .adapter, localPrinterId: printerId)` instead of directly writing to `self.states`. Remove `states` and `stateSources` properties from `AdapterRegistry`.
  - File: `PrintParty/Core/Adapters/AdapterRegistry.swift`
  - Remove: `states`, `stateSources`, `state(for:)`, `stateSource(for:)` properties
  - The pump task becomes purely: read from adapter stream → call `StateStore.ingest`
  - Rationale: the pump is no longer responsible for merge logic; it just forwards.

- [ ] **3.4. Refactor `LiveActivityCoordinator` push path to write to `StateStore`.**
  In `observeContentState`, call `StateStore.shared.ingest(state, from: .push, localPrinterId: localId)` instead of (or in addition to) updating `pushDeliveredStates`. The `pushDeliveredStates` dictionary can remain for the coordinator's own bookkeeping but is no longer the bridge to the UI.
  - File: `PrintParty/Core/LiveActivity/LiveActivityCoordinator.swift`
  - Rationale: push-delivered state flows through the same pipeline as adapter state.

- [ ] **3.5. Update `LiveActivityCoordinator` to read from `StateStore`.**
  The `reconcile()` and `handle()` methods currently read `registry.states`. Change them to read `StateStore.shared.states`. The coordinator should also subscribe to `StateStore` changes for event-driven updates rather than relying solely on its 1Hz polling.
  - File: `PrintParty/Core/LiveActivity/LiveActivityCoordinator.swift`
  - Rationale: the coordinator consumes from the unified store like any other subscriber.

- [ ] **3.6. Have `StateStore.ingest` notify the `LiveActivityCoordinator`.**
  After writing a state, `StateStore` calls `LiveActivityCoordinator.shared.notify(state:)`. This replaces the current call in the pump task. Now the Live Activity is updated regardless of which source delivered the state.
  - File: `PrintParty/Core/State/StateStore.swift`
  - Rationale: centralizes the notification; prevents future sources from forgetting to notify.

- [ ] **3.7. Update all UI references from `AdapterRegistry` to `StateStore`.**
  - `PrinterDetailView.swift`: change `registry.state(for:)` → `StateStore.shared.state(for:)`, `registry.stateSource(for:)` → `StateStore.shared.stateSource(for:)`. The `registry` property is only needed for adapter-specific operations (if any remain).
  - `PrinterRowView.swift`: same change — read `state` and `source` from `StateStore.shared`.
  - Any other views that read `AdapterRegistry.states` or `AdapterRegistry.stateSources`.
  - Files: `PrinterDetailView.swift`, `PrinterRowView.swift`, and any other views found via search.
  - Rationale: the UI layer depends only on `StateStore`, not on adapter implementation details.

- [ ] **3.8. Add convenience accessors on `StateStore` matching the old `AdapterRegistry` API.**
  - `func state(for printer: Printer) -> PrintJobState` — returns stored state or synthesized idle
  - `func stateSource(for printer: Printer) -> StateSource` — returns stored source or `.adapter`
  - Rationale: minimizes diff in view code during migration.

- [ ] **3.9. Remove the push fallback check from the pump task.**
  The old logic in `AdapterRegistry.swift:70-76` that checks `LiveActivityCoordinator.shared.pushState(for:)` is no longer needed — the push path writes directly to `StateStore`. Delete this conditional and the import/dependency on `LiveActivityCoordinator` from the pump.
  - File: `PrintParty/Core/Adapters/AdapterRegistry.swift`
  - Rationale: eliminates the special-case fallback in favor of the unified pipeline.

- [ ] **3.10. Add `removeState(for:)` to `StateStore`.**
  Called by `AdapterRegistry.unregister()` to clean up state when a printer is deleted. Also used by the coordinator to clean up push state on activity end.
  - File: `PrintParty/Core/State/StateStore.swift`
  - Rationale: complete lifecycle management in the store.

### Phase 4 — Testing and Validation

- [ ] **4.1. Manual test: push fallback flow.**
  Start a print on a gateway-connected printer, leave Wi-Fi (or kill the gateway), verify the UI transitions from green "Gateway" label to orange "Push" label within seconds of the first APNs push arriving. Verify the push fallback banner appears in `PrinterDetailView`. Verify progress updates continue arriving via push.

- [ ] **4.2. Manual test: WebSocket reconnection.**
  Start connected to the gateway on Wi-Fi. Toggle Wi-Fi off on the phone. Wait 30+ seconds. Toggle Wi-Fi back on. Verify the WebSocket reconnects within ~5 seconds (not 60+). Verify the UI transitions from offline/push back to green "Gateway" with live data.

- [ ] **4.3. Manual test: push → adapter transition.**
  While in push fallback mode, return to home Wi-Fi. Verify the WebSocket reconnects and the UI seamlessly switches from `.push` to `.adapter` source. Verify state continuity (no missing updates or progress jumps).

- [ ] **4.4. Unit test: `StateStore.ingest` staleness logic.**
  Write tests verifying: newer adapter state replaces older push state; newer push state replaces older offline adapter state; older push state does NOT replace newer adapter state; same-timestamp uses source priority.

- [ ] **4.5. Unit test: `NetworkMonitor` reconnect trigger.**
  Mock `NWPathMonitor` to simulate path transitions. Verify `GatewayStreamClient` resets `reconnectAttempt` and calls `connect()` on satisfied transition.

---

## Verification Criteria

- When the WebSocket is offline and a push arrives, `StateStore.states[printerId]` updates within one run-loop cycle
- `PrinterRowView` shows orange "Push" dot and label when `stateSource == .push`
- `PrinterDetailView` shows the orange push fallback banner when `stateSource == .push`
- Returning to home Wi-Fi triggers a WebSocket reconnect within 5 seconds (not 60+)
- After reconnect, `stateSource` reverts to `.adapter` and the push banner disappears
- Adding a hypothetical new adapter (e.g. `OctoPrintAdapter`) requires: implementing `PrinterAdapter`, registering in `AdapterRegistry.makeAdapter`, and zero changes to `StateStore`, `LiveActivityCoordinator`, or any view
- `pushDeliveredStates` updates from `LiveActivityCoordinator` reach `StateStore` without any adapter pump involvement

---

## Potential Risks and Mitigations

1. **Race condition between push and adapter on reconnect.**
   When the WebSocket reconnects, both the adapter pump and a stale push may write to `StateStore` simultaneously. Mitigation: the `updatedAt` staleness guard plus source priority ensures the fresher/higher-priority value wins. All writes are `@MainActor`-isolated, serialized on the main actor.

2. **Circular dependency: `StateStore` → `LiveActivityCoordinator` → `StateStore`.**
   `StateStore.ingest` notifies the coordinator, which may call back into the store. Mitigation: the coordinator's `notify(state:)` only updates the Live Activity (ActivityKit calls), it does not write back to `StateStore`. The push observation path writes to `StateStore` but only on push events, not on coordinator notifications. No cycle.

3. **Breaking change surface in views.**
   Every view that reads `AdapterRegistry.states` must switch to `StateStore`. Mitigation: the migration is mechanical (find-and-replace `registry.state(for:)` → `StateStore.shared.state(for:)`). Adding identical convenience methods on `StateStore` minimizes the diff.

4. **`NWPathMonitor` false positives.**
   Network path changes fire on VPN connects, cellular handoffs, etc. — not just Wi-Fi. Mitigation: each trigger just calls `connect()` which is a fast no-op if already connected (the existing guard checks `started`). Add a check: only trigger reconnect if `task == nil` (no active connection).

5. **Widget extension impact.**
   The `Shared/` module is used by the widget extension. `StateStore` lives in the app target only — the widget reads state from the `ActivityKit` content state, not from `StateStore`. No impact on the widget.

---

## Alternative Approaches

1. **Combine-based merge instead of `StateStore`**: Use `Publishers.Merge` to combine an adapter stream publisher with a push state publisher, feeding a single `@Published` dictionary. Trade-off: more reactive but adds Combine dependency to an otherwise async/await codebase; harder to debug ordering issues.

2. **Polling `pushDeliveredStates` from `AdapterRegistry`**: Instead of a new `StateStore`, add a timer in `AdapterRegistry` that periodically checks `pushDeliveredStates` for any printer whose adapter is offline. Trade-off: simpler change but perpetuates the tight coupling and adds latency proportional to poll interval. Not recommended.

3. **`withObservationTracking` on `pushDeliveredStates`**: Use Swift Observation's tracking API in the pump task to re-evaluate when `pushDeliveredStates` changes. Trade-off: clever but fragile — `withObservationTracking` is designed for SwiftUI's render loop, not for business logic; the re-trigger semantics are single-shot and would need re-registration on every change.

---

## File Change Summary

| File | Action | Phase |
|------|--------|-------|
| `PrintParty/Core/State/StateStore.swift` | **New** — unified state store | 3 |
| `PrintParty/Core/Net/NetworkMonitor.swift` | **New** — NWPathMonitor wrapper | 2 |
| `PrintParty/Core/Adapters/AdapterRegistry.swift` | **Modify** — extract state to StateStore, simplify pump | 1, 3 |
| `PrintParty/Core/LiveActivity/LiveActivityCoordinator.swift` | **Modify** — push state writes to StateStore, read from StateStore | 1, 3 |
| `PrintParty/Core/Net/GatewayStreamClient.swift` | **Modify** — add NetworkMonitor integration, TCP timeout, reset backoff | 2 |
| `PrintParty/Features/PrinterDetail/PrinterDetailView.swift` | **Modify** — read from StateStore instead of AdapterRegistry | 3 |
| `PrintParty/Features/PrintersList/PrinterRowView.swift` | **Modify** — read from StateStore instead of AdapterRegistry | 3 |
| `Shared/Adapters/PrinterAdapter.swift` | **No change** — protocol stays as-is | — |
| `Shared/Domain/PrintJobState.swift` | **No change** — model stays as-is | — |

## Recommended Execution Order

Phases 1 and 2 can be done in parallel (they touch different files). Phase 3 depends on Phase 1 being done first (since Phase 3 subsumes the `ingestPushState` method into `StateStore`). Phase 4 runs after all three.

If shipping incrementally: Phase 1 alone fixes the critical user-facing bug (push fallback not reaching UI) with minimal risk. Phase 2 alone fixes reconnection. Phase 3 is a refactor that can come in a subsequent release.
