# PrintParty — Architecture & Implementation Plan

## Objective

Build PrintParty: an iOS app whose primary user-facing surface is a **Live Activity / Dynamic Island** that tracks 3D print progress in real time. The system must:

- Work for any printer brand via a pluggable adapter model (first target: **Bambu Lab A1 Mini**).
- Work **anywhere** (cellular, foreign Wi‑Fi) — not just on the user's LAN.
- Support both a **hosted (SaaS) mode** and a **self-hosted bridge** for privacy-conscious users.
- Keep the iOS client deliberately "dumb" about transports — it only consumes a normalized event/state stream and renders Live Activities.

Success means: starting a print on the A1 Mini causes a Live Activity to appear on the user's iPhone within seconds, updates at least every ~30–60s with progress/temps/ETA/stage, and reliably ends (success, failure, cancel) — even when the phone is off-Wi‑Fi.

---

## Project Structure Summary

Current repository is a fresh SwiftUI + SwiftData Xcode template:

- `PrintParty/PrintPartyApp.swift:11-32` — App entry, SwiftData `ModelContainer` for `Item`.
- `PrintParty/ContentView.swift:11-61` — Template list UI; needs to be replaced.
- `PrintParty/Item.swift:11-18` — Template model; will be replaced by domain models.
- `PrintParty.xcodeproj/project.pbxproj` — Single iOS app target only; no widget/extension/test targets yet.

There is no networking, no extensions, no server code. This is a true greenfield, which gives us freedom to set up the right module/target layout from day one.

---

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          iOS App  (PrintParty)                           │
│  ┌──────────────┐  ┌────────────────────────┐  ┌─────────────────────┐  │
│  │   App UI     │  │  Live Activity Widget  │  │  Push Notification  │  │
│  │ (SwiftUI)    │  │  (WidgetKit + AK)      │  │  Service Extension  │  │
│  └──────┬───────┘  └────────────┬───────────┘  └─────────┬───────────┘  │
│         │                       │                        │              │
│         ▼                       ▼                        ▼              │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │   PrintPartyKit (Swift Package, shared by app + widget + ext)      │  │
│  │   • Domain models (PrinterState, PrintJob, FilamentState, ...)     │  │
│  │   • API client (REST + WebSocket to gateway)                       │  │
│  │   • Auth / device-token storage (Keychain)                         │  │
│  │   • Bambu LAN MQTT client (optional, used when on-network)         │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │  HTTPS + WebSocket + APNs LiveActivity push
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                  Cloud Service: PrintParty Gateway                       │
│   ┌──────────────┐  ┌───────────────┐  ┌──────────────────────────────┐  │
│   │   REST API   │  │ APNs Pusher   │  │  State Store (Postgres +     │  │
│   │  (accounts,  │  │ (.p8 token,   │  │  Redis live cache, per-      │  │
│   │   printers,  │  │  LiveActivity │  │  printer event stream)       │  │
│   │   tokens)    │  │  push type)   │  │                              │  │
│   └──────────────┘  └───────┬───────┘  └──────────────┬───────────────┘  │
│                             ▲                          ▲                 │
│   ┌─────────────────────────┴──────────────────────────┴─────────────┐   │
│   │      Adapter Workers (one per supported integration)              │  │
│   │   ┌────────────────┐  ┌─────────────────┐  ┌──────────────────┐  │   │
│   │   │ Bambu Cloud    │  │ Self-host Bridge│  │ OctoPrint /      │  │   │
│   │   │ MQTT consumer  │  │ inbound channel │  │ Moonraker / ...  │  │   │
│   │   └────────┬───────┘  └────────┬────────┘  └────────┬─────────┘  │   │
│   └────────────┼───────────────────┼────────────────────┼────────────┘   │
└────────────────┼───────────────────┼────────────────────┼────────────────┘
                 │                   │                    │
        Bambu Cloud MQTTS      Outbound WSS from     Adapter-specific
       us.mqtt.bambulab.com    user's home network   (HTTP/MQTT/WS)
                                     │
                                     ▼
                       ┌────────────────────────────┐
                       │   PrintParty Bridge        │
                       │   (Docker / binary, runs   │
                       │    on user's LAN)          │
                       │   • Local MQTT → Bambu     │
                       │   • Outbound WSS to gateway│
                       │   • Zero inbound ports     │
                       └────────────────────────────┘
```

### Key architectural decisions (with rationale)

1. **Server-pushed Live Activities are mandatory.** ActivityKit supports starting/updating activities via APNs with the `liveactivity` push type (iOS 16.2+, iOS 17.2+ for remote start). Since the phone may be off-Wi‑Fi, the iOS client cannot be the source of truth — a server must hold the APNs push token and emit updates.
2. **Normalized domain model in the middle.** All adapters translate vendor telemetry into a single `PrintJobState` schema. Live Activity widget code only knows that schema. This is what makes future printer support cheap.
3. **Two ingestion paths, one pipeline.** Bambu Cloud relay (zero user setup, requires storing Bambu credentials) and a self-hosted bridge (privacy mode, only outbound connections). Both publish into the same normalized event bus.
4. **Outbound-only bridge.** Self-hosted bridges open a persistent WebSocket *outbound* to the gateway. No port-forwarding, no dynDNS, works behind CGNAT — this is what makes "works anywhere" practical.
5. **Per-activity push token, not per-device.** ActivityKit issues a fresh APNs token per Live Activity. The iOS app must POST that token to the gateway bound to a `printJobId` so the gateway can target updates correctly.
6. **Budget-aware updates.** APNs throttles Live Activity pushes (~roughly one per minute average, with bursts). The gateway must debounce — coalesce rapid telemetry into "meaningful change" deltas (progress %, stage change, temp delta > N°C, ETA jump, error).
7. **8/12-hour ceiling fallback.** Live Activities expire (~8h default, up to 12h with `stale` extension). Long prints must be supported by: (a) requesting extended activity, (b) when nearing TTL push a "starts new activity" prompt via standard notification, (c) gracefully end with final-state push.

---

## Bambu Lab A1 Mini Integration Notes (informing design)

Findings synthesized from publicly reverse-engineered behavior (community projects such as `ha-bambulab`, `OpenBambuAPI`, `bambulabs-api`):

- **Transport:** MQTT over TLS on port 8883.
- **LAN mode:** Broker is the printer itself; username `bblp`, password = LAN access code shown on the printer screen; uses self-signed cert (client must skip strict CA validation or pin). Requires "LAN-only" / developer mode enabled on the printer.
- **Cloud mode:** Broker `us.mqtt.bambulab.com:8883` (regional variants exist). Auth uses a Bambu account access token obtained from `bambulab.com` login (email + password, often + email verification code, sometimes captcha). Tokens expire and must be refreshed.
- **Topics:** `device/<serial>/report` (telemetry, JSON) and `device/<serial>/request` (commands). Telemetry includes `mc_percent`, `mc_remaining_time`, `gcode_state` (IDLE/PREPARE/RUNNING/PAUSE/FINISH/FAILED), `nozzle_temper`, `bed_temper`, `layer_num`, `total_layer_num`, `subtask_name`, AMS/filament info, HMS error codes.
- **Camera/snapshot:** A1 Mini exposes RTSP-like snapshots; non-essential for Live Activity v1 but useful for the in-app detail screen later.
- **Fragility:** Bambu has, in past firmware updates, restricted LAN access. Plan must assume LAN mode may be limited and the **cloud relay is the more durable path** even for local users. The self-hosted bridge therefore must support *both* (a) talking to the local printer MQTT and (b) talking to Bambu Cloud MQTT on the user's behalf so that users can choose privacy posture independently from network reachability.

---

## Implementation Plan

### Phase 0 — Foundations & Project Restructure

- [ ] Task 0.1. Replace the SwiftData `Item` template with the real domain. Define `PrintJobState` (normalized) and supporting enums (`PrinterStage`, `JobOutcome`) in a new Swift Package `PrintPartyKit` so it is shareable between the app target, the future widget extension, and the future notification service extension. Rationale: Live Activity widgets run in a separate process and must link the same models without code duplication.
- [ ] Task 0.2. Add Xcode targets: (a) `PrintPartyWidgetExtension` (WidgetKit + ActivityKit), (b) `PrintPartyNotificationService` (mutable-content APNs for image previews / debugging later), (c) `PrintPartyKitTests`. Wire all of them to the shared package. Rationale: Live Activities are declared in a widget extension; getting the target topology right early avoids painful refactors.
- [ ] Task 0.3. Enable required entitlements/capabilities in the app: Push Notifications, Background Modes (remote notifications), `NSSupportsLiveActivities = YES` and `NSSupportsLiveActivitiesFrequentUpdates = YES` in `Info.plist`. Rationale: required for server-pushed Live Activity updates and to remove the per-hour budget cap for high-frequency updates.
- [ ] Task 0.4. Set up an APNs auth key (.p8) in the Apple Developer portal scoped for the app's bundle id and store its metadata (Team ID, Key ID) as gateway secrets. Rationale: token-based APNs auth is the only viable option for a multi-tenant gateway.

### Phase 1 — Normalized Domain Model & Live Activity UI

- [ ] Task 1.1. Design `PrintJobState` to be the *single source of truth* for the Live Activity. Suggested fields: `printerId`, `printerDisplayName`, `printerModel`, `jobId`, `jobName`, `stage` (idle/preparing/printing/paused/finishing/done/failed/canceled), `progressPercent`, `currentLayer`, `totalLayers`, `startedAt`, `estimatedEndAt`, `nozzleTempC`, `nozzleTargetC`, `bedTempC`, `bedTargetC`, `errorCode?`, `errorMessage?`, `thumbnailURL?`, `updatedAt`. Rationale: a stable contract decouples vendor adapters from UI.
- [ ] Task 1.2. Define a corresponding `ActivityAttributes` (`static` printer identity) and `ContentState` (dynamic job state, kept compact — APNs payload <4KB after JSON). Keep the `ContentState` lean: numeric fields, no images, no long strings. Rationale: APNs Live Activity payload size limit and update efficiency.
- [ ] Task 1.3. Implement the Live Activity views: Lock Screen / Banner layout, Dynamic Island compact / minimal / expanded variants. Use `Text(timerInterval:)` for ETA to avoid pushing every second. Render stage, %, layer x/y, and a compact temp summary. Rationale: leveraging built-in timer views reduces required push frequency dramatically.
- [ ] Task 1.4. Build an in-app "Printers" screen and "Active Print" detail screen using SwiftUI + SwiftData (persist printer registrations locally; canonical printer list lives on the server). Rationale: users need to see status when the Live Activity isn't visible.

### Phase 2 — Gateway Service (cloud component)

- [ ] Task 2.1. Choose a server stack and stand up the gateway skeleton. Recommendation: **Swift on Server (Vapor)** for code reuse with the iOS team (shared DTOs via a Swift package) — alternative: Go or Node/TypeScript if hiring/operational considerations favor it. Document the trade-off in an ADR. Rationale: domain model fidelity and team focus.
- [ ] Task 2.2. Define the REST surface: `POST /v1/auth/*` (sign-up/sign-in, magic-link or Sign-in with Apple), `GET/POST /v1/printers`, `POST /v1/printers/{id}/credentials` (Bambu account or LAN code), `POST /v1/activities` (register a Live Activity push token bound to a `printJobId`), `DELETE /v1/activities/{id}`, `GET /v1/printers/{id}/state` (REST snapshot for app cold-start). Rationale: clean separation between control plane and the push data plane.
- [ ] Task 2.3. Stand up persistence: Postgres for users/printers/credentials/activity tokens; Redis for current `PrintJobState` per printer and short-lived dedupe. Rationale: Postgres for durability, Redis for hot-path debouncing performance.
- [ ] Task 2.4. Implement an APNs client using token-based auth with HTTP/2 multiplexing and the `liveactivity` push type. Support both `event=update` and `event=end`, set `apns-priority: 10`, `apns-push-type: liveactivity`, and dynamic `stale-date` / `dismissal-date`. Rationale: correct headers are mandatory or pushes are silently dropped.
- [ ] Task 2.5. Build the **update coalescer**. Inputs: raw telemetry events. Outputs: at most one APNs push per printer per ~30–60s, *immediately* on stage/error transitions, and final state on completion. Track per-activity push budget and back off gracefully. Rationale: ActivityKit budget enforcement and battery considerations.
- [ ] Task 2.6. Encrypt sensitive credentials (Bambu account tokens, LAN access codes) at rest with a KMS-managed key; rotate Bambu access tokens automatically. Rationale: credential blast radius if the DB is exfiltrated.

### Phase 3 — Bambu Cloud Adapter (zero-setup path)

- [ ] Task 3.1. Implement a Bambu account login flow on the gateway: email + password, handle email verification challenge, store refresh/access tokens. Provide a fall-through to "device-token-only" mode if Bambu later exposes per-device API tokens. Rationale: works for any Bambu user without home network configuration; this is the "it just works" path needed before launch.
- [ ] Task 3.2. Implement a long-lived MQTT subscriber (per-user connection or pooled, depending on Bambu's connection rules) that subscribes to `device/<serial>/report` for each registered printer and parses telemetry. Rationale: this is the live data feed.
- [ ] Task 3.3. Implement a `BambuTelemetry → PrintJobState` mapper. Handle partial-update messages (Bambu sometimes sends deltas), retain last full state per printer in Redis, and synthesize `jobId` boundaries (job starts when `gcode_state` enters PREPARE/RUNNING after IDLE; job ends on FINISH/FAILED). Rationale: Bambu does not send a clean per-job id; the gateway must derive one.
- [ ] Task 3.4. Add reconnection, exponential backoff, and credential-refresh handling. Emit a `printerOffline` state when the broker hasn't produced telemetry in N minutes during an active job. Rationale: silent disconnects are common; the user must be told.

### Phase 4 — iOS Client ↔ Gateway Wiring

- [ ] Task 4.1. Implement sign-up/sign-in in the iOS app (prefer Sign in with Apple). Store the resulting bearer token in Keychain via `PrintPartyKit`. Rationale: minimal friction, no password storage.
- [ ] Task 4.2. Implement the "Add Bambu Printer" flow: ask for Bambu account credentials (or, if user prefers, LAN access code + serial + IP/mDNS lookup later), POST securely to the gateway, surface validation errors. Rationale: must succeed end-to-end before any Live Activity can fire.
- [ ] Task 4.3. Implement Live Activity lifecycle on the client. On detecting (via WebSocket or REST poll) that a print has started, call `Activity.request(...)` and, for each activity, await `pushTokenUpdates` and POST each token to `POST /v1/activities` bound to `printJobId`. On `end` event, call `Activity.end(...)` with final content. Rationale: per-activity tokens are the only way to push.
- [ ] Task 4.4. Implement a foreground WebSocket subscription to gateway events so the in-app UI updates live independent of APNs. Rationale: in-app responsiveness shouldn't be hostage to APNs throttling.
- [ ] Task 4.5. Optional optimization: when iOS app detects it is on the same LAN as a registered Bambu printer (Bonjour/mDNS or stored SSID hint), open a *direct* MQTT subscription in addition to the gateway feed and prefer the lower-latency local stream for in-app UI (still rely on gateway for Live Activity pushes). Rationale: best-of-both UX without complicating the push path.

### Phase 5 — Self-Hosted Bridge (privacy mode)

- [ ] Task 5.1. Define the bridge protocol: bridge opens an outbound WSS to `bridge.printparty.app/v1/link`, authenticates with a pairing token generated in-app, and streams normalized `PrintJobState` events upward. Server may send commands downward (pause/resume/cancel in v2). Rationale: outbound-only design works behind CGNAT/NAT/firewalls with zero user network config.
- [ ] Task 5.2. Pairing UX: in the iOS app, show a 6-digit code + QR; user pastes/scans into the bridge's local web UI. Bridge exchanges the code for a long-lived bridge token at the gateway. Rationale: avoids requiring users to type long secrets into the bridge.
- [ ] Task 5.3. Build the bridge as a single small binary (recommendation: **Go** for static binary, or **Swift on Linux** for code reuse). Ship as: (a) a Docker image (`ghcr.io/printparty/bridge:latest`), (b) a Home Assistant add-on, (c) a Raspberry Pi install script, (d) optionally a Synology/Unraid package. Rationale: meet users where they already self-host.
- [ ] Task 5.4. Bridge implements the same `BambuTelemetry → PrintJobState` mapper from Phase 3 (shared library). Configurable to talk to the local printer MQTT (default) and/or Bambu Cloud (fallback). Rationale: code reuse; user gets identical behavior with different trust boundary.
- [ ] Task 5.5. Operational features: health endpoint, structured logs, automatic update channel (or clear update instructions), redaction of secrets in logs. Rationale: self-hosting users will debug; we should make that pleasant.

### Phase 6 — Adapter Abstraction & Second Printer

- [ ] Task 6.1. Refactor the Bambu adapter behind a clean interface (e.g., `protocol PrinterAdapter { func start(...) -> AsyncStream<PrintJobState> }` in shared library) so both the gateway workers and the bridge consume it uniformly. Rationale: this is the abstraction that makes the project a *platform*, not a Bambu app.
- [ ] Task 6.2. Implement a second adapter to prove the abstraction. Recommended: **OctoPrint** (well-documented REST + WebSocket, large install base) or **Moonraker/Klipper** (also WebSocket + JSON-RPC). Rationale: validates the model on a fundamentally different transport.
- [ ] Task 6.3. Document an Adapter Authoring Guide so external contributors can add printers (Prusa Connect, Creality Cloud, Anycubic, etc.). Rationale: third-party contributions are the long-term growth path.

### Phase 7 — Reliability, Long Prints & Polish

- [ ] Task 7.1. Implement long-print handling: request maximum-duration Live Activities, monitor remaining TTL on the server, send a regular push notification ~15 min before expiry inviting the user to tap to re-arm a new activity. Rationale: graceful UX for >8h prints, which are common.
- [ ] Task 7.2. Implement final-state guarantees: on `FINISH`/`FAILED`/`CANCELED`, send a single high-priority `event=end` push with the final `ContentState` and `dismissal-date`, plus a regular notification with summary + thumbnail. Rationale: users must learn the outcome even if the Live Activity already auto-dismissed.
- [ ] Task 7.3. Add an APNs-failure observability path (BadDeviceToken, ExpiredToken cleanup) and per-user push-budget telemetry to detect throttling. Rationale: silent push failures are the #1 way these features rot in production.
- [ ] Task 7.4. Add automated tests: contract tests for `BambuTelemetry → PrintJobState`, replay tests with recorded MQTT captures, snapshot tests for Live Activity views, and an end-to-end staging test against a real A1 Mini. Rationale: regressions in mapping logic are silent and brand-damaging.

---

## Verification Criteria

- Starting a print on the A1 Mini causes a Live Activity to appear on the registered iPhone within **≤ 15 seconds**, when the phone is on cellular (off the home Wi‑Fi).
- The Live Activity updates progress and ETA at least every **60 seconds** during a print, and updates **immediately** (≤ 5s) on stage transitions (preparing → printing → paused → done/failed).
- When the print finishes, fails, or is canceled, the Live Activity transitions to a final terminal state via an `end` push and a confirmation notification is delivered.
- Removing all home-network access (only Bambu Cloud reachable) still yields a functioning Live Activity (proves cloud-relay path).
- Running only the self-hosted bridge with the user's Bambu *credentials never stored in our cloud* still yields a functioning Live Activity (proves privacy path).
- The gateway respects APNs Live Activity push budgets without being throttled (observable via APNs response codes and internal budget metrics).
- A second printer adapter (OctoPrint or Moonraker) can be added without modifying the iOS app, the widget, or the APNs pusher — only the new adapter and its config UI.
- All sensitive credentials (Bambu tokens, LAN codes, bridge pairing tokens) are stored encrypted at rest and never logged.

---

## Potential Risks and Mitigations

1. **Bambu changes/breaks unofficial cloud MQTT access.** This has happened to similar projects.
   Mitigation: ship the self-hosted bridge from day one as a first-class path, not an afterthought. Keep the gateway adapter swappable. Watch upstream community projects (`ha-bambulab`, `bambulabs-api`) for early warning. Consider a "BYO Bambu credentials, run in your own gateway container" deployment as a final fallback.
2. **Apple Live Activity push budget throttling.** Excessive updates will be dropped or delay the entire app.
   Mitigation: aggressive coalescing in the gateway, only push on meaningful change, lean on `Text(timerInterval:)` for ETA rather than per-second pushes, enable the frequent-updates entitlement, instrument APNs response codes.
3. **8 / 12-hour Live Activity TTL vs. multi-day prints.** Activity will auto-dismiss before the print finishes.
   Mitigation: Phase 7 fallback — pre-expiry standard notification with a "Resume tracking" deep link that requests a fresh activity, and always send a definitive `end` push and outcome notification.
4. **User credential trust (storing Bambu account passwords/tokens server-side).** Security and privacy risk.
   Mitigation: KMS-encrypted at rest, scoped per-user keys, prefer refreshable access tokens over long-lived passwords, allow the user to choose self-hosted mode where credentials never leave their network.
5. **NAT / CGNAT / restrictive home networks prevent any inbound access.**
   Mitigation: bridge is strictly outbound WSS — no port forwarding, no UPnP, no public IP needed.
6. **Live Activity push token churn (new token per activity, can rotate mid-activity).** A stale-token bug silently breaks updates.
   Mitigation: client must observe `pushTokenUpdates` (not just initial token) and POST every rotation to the gateway; gateway must accept token updates idempotently.
7. **Multi-printer households or shared printers (multiple phones, one printer).**
   Mitigation: model `Activity` registrations as many-to-one with `printerId`; gateway fans out APNs pushes to all registered activities for that printer.
8. **A1 Mini firmware tightening LAN mode.**
   Mitigation: do not depend on LAN MQTT as the only path; treat LAN as an optimization, cloud (direct or via bridge) as the contract.
9. **Cost of running the hosted gateway.** Long-running MQTT subscribers + APNs traffic per user scale linearly with active users.
   Mitigation: pool MQTT connections where Bambu allows it; design the bridge path to be the default for "power users" so hosted gateway is mostly the on-ramp; choose a stack (Swift/Go) with low per-connection memory.

---

## Alternative Approaches

1. **Client-only LAN-only app (no gateway).** The iOS app talks MQTT directly to the printer over LAN; uses local Live Activity updates (no APNs).
   Trade-offs: zero server cost and zero credential storage, but **breaks the "works anywhere" requirement** — Live Activities cannot update meaningfully when the phone is off-network or asleep without push. Rejected as the primary architecture; useful as an in-app enhancement (Task 4.5).
2. **Pure SaaS, no self-hosted bridge.** Only the cloud relay path is supported.
   Trade-offs: simpler to build and operate, but cedes the privacy-minded segment of the 3D printing community (which is large and vocal, especially after the Bambu cloud controversies), and gives us a single point of failure if Bambu breaks cloud MQTT. Rejected as the only option; viable as launch v0.5 with the bridge following in v1.0.
3. **Pure self-hosted, no SaaS.** Every user must run the bridge.
   Trade-offs: best privacy and lowest operating cost, but huge onboarding friction and excludes non-technical users. Rejected as primary; the bridge should be available but optional.
4. **Use Home Assistant as the bridge.** Lean on existing `ha-bambulab` integration; PrintParty becomes a thin layer that subscribes to HA and pushes APNs.
   Trade-offs: massively accelerates Bambu (and many other printers) support, but locks PrintParty to users who already run HA. Recommended as a *secondary* deployment mode (Task 5.3 — ship a Home Assistant add-on) but not as the only bridge.
5. **Server in Go vs. Swift on Server.** Go gives better operational maturity, smaller binaries, simpler ops; Swift gives shared types end-to-end with the iOS app.
   Trade-offs: shared types pay off most heavily for the `PrintJobState` contract — bugs there are the most expensive. Recommendation: Swift/Vapor for the gateway, Go for the bridge binary (smaller distribution footprint, easier cross-compilation for Pi/NAS).

---

## Assumptions Made

- Target iOS 17.2+ (full server-pushed Live Activity feature set including remote start). Older OS versions will get a degraded experience (in-app only).
- A custom domain and APNs credentials can be obtained for the project.
- The Bambu A1 Mini's MQTT topic/payload format remains broadly compatible with what community projects have documented; if it diverges, the mapper in Task 3.3 is the only place that must change.
- Users are willing to either (a) enter Bambu account credentials into the hosted service, or (b) run a small bridge container at home. If neither is true, the project's "works anywhere" promise cannot be met for that user.
- A single Apple Developer account / App Store listing will be used; multi-region hosting can be deferred until there is demand.
