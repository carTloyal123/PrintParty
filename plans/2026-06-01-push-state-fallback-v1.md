# Push-Derived State Fallback

## Objective

When the iOS app can't reach the gateway over WebSocket (off-network, gateway unreachable), fall back to displaying the most recent state delivered via APNs push through the Live Activity. This eliminates the jarring UX where the Lock Screen shows live progress but the app shows "Offline."

## Current Data Flow

```
Gateway ──WebSocket──▶ GatewayAdapter ──▶ AdapterRegistry.states ──▶ UI
Gateway ──Relay/APNs──▶ ActivityKit ──▶ Live Activity widget (Lock Screen only)
```

The two paths are completely independent. The app UI only reads from `AdapterRegistry.states`, which is fed exclusively by the WebSocket. When the WebSocket drops, the adapter emits an `.offline` state and the UI shows disconnected — even though APNs is still delivering updates to the Live Activity.

## Proposed Data Flow

```
Gateway ──WebSocket──▶ GatewayAdapter ──▶ AdapterRegistry.states ──▶ UI  (primary)
                                                  ▲
Gateway ──Relay/APNs──▶ ActivityKit ──▶ LiveActivityCoordinator ─┘       (fallback)
```

When the WebSocket adapter reports `.offline`, the system falls back to the Live Activity's `contentState` as the display state.

## Implementation Plan

### Layer 1: LiveActivityCoordinator exposes push-delivered state

- [ ] Task 1. Add a `pushDeliveredStates: [UUID: PrintJobState]` dictionary to `LiveActivityCoordinator` that stores the latest content state from each active Live Activity.
- [ ] Task 2. In `observePushToken`, also observe `activity.contentStateUpdates` (the ActivityKit async sequence that emits every time APNs delivers a new content state). On each update, decode it and store in `pushDeliveredStates[printerId]`.
- [ ] Task 3. Add a public method `pushState(for printerId: UUID) -> PrintJobState?` that returns the latest push-delivered state if available.

**Rationale:** This gives the rest of the app access to the APNs-delivered state without coupling UI code directly to ActivityKit.

### Layer 2: AdapterRegistry merges push fallback

- [ ] Task 4. In `AdapterRegistry`, when the pump task receives a new state from an adapter and the stage is `.offline`, check `LiveActivityCoordinator.shared.pushState(for: state.printerId)`. If a push-delivered state exists and is more recent (by `updatedAt`), use it instead — but annotate it so the UI knows the source.
- [ ] Task 5. Add a `stateSource: [UUID: StateSource]` dictionary to `AdapterRegistry` (enum: `.adapter`, `.push`). Update it whenever a state is stored. The UI reads this to decide whether to show a "via push" banner.

**Rationale:** Centralizes the fallback logic in one place. The UI layer doesn't need to know about ActivityKit — it just reads `states` and `stateSource` from the registry.

### Layer 3: UI indicates push-fallback mode

- [ ] Task 6. In `PrinterRowView`, when `stateSource` is `.push`, change the connection dot to an orange/yellow color and the connection label to "Push" with a `antenna.radiowaves.left.and.right` icon, instead of showing a red "offline" dot.
- [ ] Task 7. In `PrinterDetailView`, when the source is `.push`, show a subtle banner at the top: "Updated via push — not connected to gateway" with a `info.circle` icon. The state data (progress, temps, stage) still renders normally.
- [ ] Task 8. In `PrinterDetailView`, the existing controls card should show a note like "Controls unavailable — not connected to gateway" when in push-fallback mode, since we can't send commands over APNs.

**Rationale:** The user sees coherent state everywhere (app, Lock Screen, Dynamic Island) with clear indication of *how* the data is arriving.

### Layer 4: Transition handling

- [ ] Task 9. When the WebSocket reconnects (adapter transitions from `.offline` to any other stage), clear the push fallback: set `stateSource` back to `.adapter` and remove the banner. The adapter's live data takes priority again.
- [ ] Task 10. When a Live Activity ends (print finishes + linger expires, or user toggles off), remove the entry from `pushDeliveredStates`. The fallback is no longer available.

**Rationale:** Clean transitions prevent stale push data from persisting after reconnection.

## Verification Criteria

- With gateway reachable: app shows live WebSocket data, green connection dot, no banner.
- With gateway unreachable + Live Activity running: app shows APNs-delivered data, orange dot, "Updated via push" banner. Progress/stage/temps update as pushes arrive.
- On WebSocket reconnect: banner disappears, dot turns green, data seamlessly transitions to live.
- With no Live Activity running + gateway unreachable: app shows "Offline" as before (no fallback available).

## Potential Risks and Mitigations

1. **Push data may be stale (APNs isn't real-time)**
   Mitigation: Show `updatedAt` timestamp in the banner so the user knows how fresh the data is. APNs typically delivers within 1-3 seconds.

2. **E2EE: the app can't decrypt the push content state**
   Mitigation: The `contentStateUpdates` async sequence on `Activity` delivers the *decoded* `ContentState` (ActivityKit handles the APNs envelope). Since `ContentState = PrintJobState` (plaintext), this works for the non-E2EE path. For E2EE, the widget extension decrypts — but the main app would need the shared key too. For now, this fallback only works with the plaintext path. E2EE fallback is a future enhancement.

3. **`contentStateUpdates` may not emit in the background**
   Mitigation: The app only needs this when it's in the foreground and the user is looking at it. `contentStateUpdates` emits in the foreground. If the app is backgrounded, the Live Activity widget handles rendering directly.

## Alternative Approaches

1. **Read from `Activity.content.state` directly in the view**: Simpler but couples SwiftUI views to ActivityKit. Hard to test and breaks separation of concerns.
2. **Poll the relay for last-known state**: Would require the relay to store state (violates its stateless design) or a new cloud endpoint.
3. **Tunnel/VPN for remote WebSocket**: The "real" solution but requires user infrastructure. Orthogonal to this change.
