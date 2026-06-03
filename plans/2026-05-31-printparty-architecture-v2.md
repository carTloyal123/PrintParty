# PrintParty — Architecture & Implementation Plan (v2)

> **What changed from v1:** PrintParty is now an **open-source, self-hosted-first** project. The project operates exactly **one** piece of infrastructure: a **stateless, end-to-end-encrypted APNs push relay**. Every other component — accounts, printer adapters, telemetry, state — is hosted by the user. Live Activity payloads are encrypted between the user's gateway and the iOS widget extension, so the relay never sees plaintext print data. A v1 "BYO-everything" path is also supported for users who want zero dependency on project infrastructure.

## Objective

Build PrintParty: an open-source iOS app whose primary surface is a **Live Activity / Dynamic Island** that tracks 3D print progress for any printer brand (first target: **Bambu Lab A1 Mini**), works **anywhere** (cellular, foreign Wi‑Fi), and is **fully self-hostable** except for an irreducible Apple-mandated push relay.

Success means:
- Starting a print on the A1 Mini causes a Live Activity on the user's iPhone within ~15 seconds, anywhere in the world, while the user is hosting only their own gateway.
- The project sees only opaque ciphertext and APNs metadata — never printer credentials, never job names, never progress.
- A new printer brand can be added by writing one adapter and no iOS code.
- A user with a paid Apple Developer account can run the entire stack — including their own push relay — with no dependency on project-operated infrastructure.

---

## Project Structure Summary

The repository is currently a fresh SwiftUI + SwiftData Xcode template:

- `PrintParty/PrintPartyApp.swift:11-32` — App entry, SwiftData `ModelContainer` for the template `Item`.
- `PrintParty/ContentView.swift:11-61` — Template list UI; will be removed.
- `PrintParty/Item.swift:11-18` — Template model; will be replaced by domain models in a shared package.
- `PrintParty.xcodeproj/project.pbxproj` — Single iOS app target; no extensions, tests, or server code yet.

Greenfield project — we have full freedom to establish the right module/target topology from day one.

---

## Trust Model & Why It Looks Like This

Apple's platform forces exactly one concession: **Live Activities can only be updated via APNs, and APNs pushes can only be sent by the holder of an APNs auth key bound to the app's bundle ID.** That means whoever distributes the iOS binary is the only party whose key can push to it.

Everything else — MQTT, state, web UI, accounts, printer adapters — is mundane software that anyone can host. So we draw the architectural line exactly at that constraint:

- **Project operates:** one stateless, open-source relay that forwards opaque payloads to APNs. No accounts. No printer data. No persistent storage beyond a registered-gateway HMAC keyfile.
- **User operates:** everything else. Their gateway holds printer credentials, runs the adapters, holds state, and encrypts Live Activity payloads before handing them to the relay.
- **End-to-end encryption** is what makes this honest: the iOS widget extension and the user's gateway share a symmetric key (established at pairing time). The gateway encrypts `ContentState` before posting to the relay. The relay forwards ciphertext to APNs. APNs delivers it to the widget extension, which decrypts and renders. The project's infrastructure never observes plaintext.
- **Escape hatch:** users with a paid Apple Developer account can rebuild the app under their own bundle ID and run their own relay with their own APNs key, eliminating all project dependency.

---

## High-Level Architecture

```
┌─────────────────────────────── User's Phone ───────────────────────────────┐
│  ┌──────────────┐  ┌────────────────────────┐  ┌───────────────────────┐  │
│  │   App UI     │  │  Live Activity Widget  │  │ Notification Service  │  │
│  │ (SwiftUI)    │  │  (WidgetKit + AK)      │  │ Extension             │  │
│  └──────┬───────┘  └────────────┬───────────┘  └──────────┬────────────┘  │
│         │                       │                          │              │
│         ▼                       ▼                          ▼              │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │ PrintPartyKit (Swift Package; linked by app + widget + ext)          │ │
│  │ • Domain models (PrintJobState, PrinterStage, ...)                   │ │
│  │ • Gateway pairing + E2EE key store (Keychain via App Group)          │ │
│  │ • Gateway client (REST + WebSocket)                                  │ │
│  │ • ContentState envelope decrypt path (widget side)                   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
└──────────┬────────────────────────────────────────────────┬───────────────┘
           │ HTTPS + WebSocket (to user's gateway, direct)   │ APNs (via relay)
           ▼                                                  ▲
┌────────────────────────────────────────────┐                │
│   User-Hosted Gateway (OSS, AGPLv3)        │   encrypted    │
│   ┌──────────────┐  ┌──────────────────┐   │   payload      │
│   │  REST + WS   │  │ E2EE Encryptor   │───┼───────────────►│
│   │  API         │  │ (per-printer key)│   │ HMAC-signed    │
│   ├──────────────┤  └──────────────────┘   │ HTTPS POST     │
│   │ Postgres /   │  ┌──────────────────┐   │                │
│   │ SQLite +     │  │ Update Coalescer │   │                │
│   │ Redis        │  └──────────────────┘   │                │
│   └──────────────┘                          │                │
│   ┌──────────────────────────────────────┐  │                │
│   │  Adapter Workers                     │  │                │
│   │  ┌──────────┐ ┌──────────┐ ┌───────┐ │  │                │
│   │  │  Bambu   │ │ OctoPrint│ │ ...   │ │  │                │
│   │  │  Cloud   │ │ Moonraker│ │       │ │  │                │
│   │  │  MQTT    │ │          │ │       │ │  │                │
│   │  └────┬─────┘ └────┬─────┘ └───────┘ │  │                │
│   └───────┼────────────┼─────────────────┘  │                │
└───────────┼────────────┼─────────────────────┘                │
            │            │                                      │
   Bambu Cloud MQTTS   OctoPrint REST/WS                        │
   or LAN MQTT         (LAN or tunneled)                        │
            │                                                   │
            ▼                                                   │
   ┌──────────────────────────┐                                 │
   │  PrintParty Bridge (opt) │                                 │
   │  Runs on user's LAN if   │                                 │
   │  gateway isn't local     │                                 │
   │  • outbound WSS to gw    │                                 │
   └──────────────────────────┘                                 │
                                                                │
┌──────────────────────────────────── Project-Operated ─────────┴────────────┐
│                  PrintParty Relay (OSS, MIT/Apache)                        │
│  • Stateless APNs forwarder for the `liveactivity` push type               │
│  • Accepts HMAC-signed POSTs from registered self-hosted gateways          │
│  • Knows: gateway public id, payload bytes, push token, APNs response      │
│  • Does NOT know: who the user is, what printer, what print, any plaintext │
│  • Storage: a single keyfile (or SQLite) of registered gateway HMAC keys   │
│  • Reproducible builds; ephemeral request logs (no payload bodies)         │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Boundaries

### iOS App (`PrintParty`) — open source, distributed via App Store

- SwiftUI app + Widget Extension (Live Activity) + Notification Service Extension.
- Stores Keychain-backed per-printer E2EE keys in an **App Group** so the widget extension can decrypt `ContentState`.
- Talks **directly to the user's gateway** for control plane (login, printer list, in-app live state via WebSocket).
- Knows the relay's URL only as the destination its activity push tokens are forwarded to — but it never speaks to the relay; the gateway does.

### User Gateway (`printparty-gateway`) — open source, AGPLv3, self-hosted

- Single binary or Docker image. Ships with SQLite by default; supports Postgres + Redis for larger setups.
- Owns: accounts (single-user by default, multi-user opt-in), printer registrations, printer credentials, telemetry state, **per-printer E2EE key**, the adapter plugin system, the update coalescer.
- Registers itself once with the relay, obtains an HMAC signing key, signs every push request.
- Exposes a local web UI for setup + a REST/WebSocket API for the iOS app.
- The **only component that ever sees plaintext print data** apart from the iOS app.

### Bridge (`printparty-bridge`) — open source, AGPLv3, optional

- Small Go binary (static, ~10 MB) for users whose gateway runs off-network from the printer.
- Opens an outbound WSS to the gateway. Translates local MQTT (Bambu LAN, OctoPrint LAN, etc.) into normalized events.
- Same `PrinterAdapter` interface as the gateway; gateway and bridge share an adapter library.
- Most users will not need it — they'll run the gateway directly on their LAN. Bridge is for the "gateway lives in a VPS, printer is at home" case.

### Push Relay (`printparty-relay`) — open source, MIT/Apache, project-operated (and optionally self-hosted)

- Stateless, single binary. Holds the APNs `.p8` key bound to the App Store bundle ID.
- Accepts `POST /v1/push` with: `{gatewayId, activityToken, encryptedPayload, nonce, signature, event}`.
- Verifies HMAC, forwards as APNs `liveactivity` push, returns APNs response code.
- Storage: registered gateway HMAC keyfile (could even be a flat file or SQLite). No payload persistence. No PII.
- Rate-limiting and abuse controls per `gatewayId`.
- Project's hosted instance is the default; users with their own Apple Developer account can run their own.

---

## End-to-End Encrypted Live Activity Payloads (Design)

### Key exchange (at printer pairing time)

When the iOS app pairs with a gateway:

1. User opens the gateway's local web UI, generates a pairing token.
2. iOS app scans QR / enters the token; performs an **X25519 Diffie–Hellman** over the gateway's TLS connection to derive a shared secret per `(device, gateway)` pair.
3. For each printer registered later, gateway derives a per-printer subkey (HKDF) from the shared secret plus the `printerId`. iOS app derives the same subkey on demand.
4. Per-printer subkey is stored in the iOS app's App Group Keychain, accessible to the widget extension.

This means the widget can decrypt any printer's payloads using only locally-derived keys, without any network round-trip at render time.

### Payload envelope

`ContentState` (the struct ActivityKit hands the widget) becomes:

```
struct ContentState {
    let printerId: String           // plaintext, used to look up the key
    let v: Int                      // schema version
    let nonce: Data                 // 12 bytes, ChaCha20-Poly1305
    let ciphertext: Data            // encrypted PrintJobState JSON
}
```

Inside `ciphertext`, after decryption: the full `PrintJobState` (progress, stage, ETA, temps, etc.) as compact JSON or CBOR. Total APNs payload must stay under the 4 KB limit, which is comfortable.

### What the relay sees

The relay sees `printerId` (an opaque UUID), `nonce`, `ciphertext`, the APNs activity token, and the gateway's HMAC signature. It cannot decrypt `ciphertext`. It cannot link `printerId` to a human or a printer brand without out-of-band correlation.

### Failure modes covered

- **Lost key on the phone (app reinstalled):** widget can't decrypt → falls back to a generic "Print in progress" banner; user re-pairs the printer to re-derive keys.
- **Compromised relay:** can deny service or replay encrypted payloads, but cannot decrypt. Replay is mitigated by including a monotonically increasing counter in the encrypted body and rejecting non-monotonic deliveries at the widget.
- **Compromised gateway:** has the keys for its own printers (by definition) but not for other users' gateways. Blast radius is one household.

---

## Implementation Plan

### Phase 0 — Foundations & Project Restructure

- [ ] Task 0.1. Replace the SwiftData `Item` template with the real domain. Define `PrintJobState` (normalized) and supporting enums in a new Swift Package `PrintPartyKit` shareable by app, widget extension, and notification service extension. Rationale: Live Activity widgets run in a separate process and must link the same models without duplication.
- [ ] Task 0.2. Add Xcode targets: (a) `PrintPartyWidgetExtension` (WidgetKit + ActivityKit), (b) `PrintPartyNotificationService`, (c) `PrintPartyKitTests`. Create an App Group entitlement shared between app and extensions for E2EE keychain access. Rationale: gets the target topology and Keychain sharing right before any business logic depends on it.
- [ ] Task 0.3. Enable required entitlements in the app: Push Notifications, Background Modes (remote notifications), `NSSupportsLiveActivities = YES`, `NSSupportsLiveActivitiesFrequentUpdates = YES`. Rationale: required for server-pushed Live Activities and to lift per-hour budget caps.
- [ ] Task 0.4. Create a `printparty/` monorepo layout (or top-level Swift package directories) that will house `gateway/`, `bridge/`, `relay/`, `adapters/`, and `clients/ios/`. Pick licenses: AGPLv3 for gateway and bridge, MIT for iOS app and relay. Rationale: AGPL on the gateway prevents commercial SaaS forks of the user data plane; MIT on the relay encourages independent operators.
- [ ] Task 0.5. Set up an APNs auth key (.p8) in the Apple Developer portal scoped for the app's bundle id; store metadata as relay secrets. Rationale: token-based APNs is the only multi-tenant-capable option.

### Phase 1 — Normalized Domain Model & E2EE Envelope

- [ ] Task 1.1. Specify `PrintJobState` as the single source of truth for the Live Activity, with fields: `printerId`, `printerDisplayName`, `printerModel`, `jobId`, `jobName`, `stage`, `progressPercent`, `currentLayer`, `totalLayers`, `startedAt`, `estimatedEndAt`, `nozzleTempC`, `nozzleTargetC`, `bedTempC`, `bedTargetC`, `errorCode?`, `errorMessage?`, `updatedAt`. Rationale: stable contract decouples vendor adapters from UI.
- [ ] Task 1.2. Define `ActivityAttributes` (static printer identity) and the E2EE `ContentState` envelope `{printerId, v, nonce, ciphertext}`. Specify the inner plaintext as compact JSON (or CBOR) of `PrintJobState`. Rationale: locks the wire format that both gateway and widget must agree on before either is written.
- [ ] Task 1.3. Implement Live Activity views: Lock Screen / Banner, Dynamic Island compact / minimal / expanded. Use `Text(timerInterval:)` for ETA. The widget decrypts `ContentState` via shared App Group keychain; if decryption fails, render a graceful "Print in progress" fallback. Rationale: leveraging `timerInterval` reduces required push frequency by an order of magnitude.
- [ ] Task 1.4. Implement the in-app "Printers" and "Active Print" screens, plus a "Gateways" screen for users with more than one self-hosted gateway. Rationale: in-app UX must work even when the Live Activity isn't visible.

### Phase 2 — Push Relay (project-operated, OSS, stateless)

- [ ] Task 2.1. Build `printparty-relay` as a small Swift on Server (Vapor) or Go service. Endpoints: `POST /v1/gateways/register` (one-shot, returns HMAC key), `POST /v1/push` (HMAC-signed forward), `GET /healthz`. Rationale: stateless surface minimizes operational and security risk.
- [ ] Task 2.2. Implement token-based APNs HTTP/2 client with the `liveactivity` push type, correct `apns-priority: 10`, dynamic `stale-date` / `dismissal-date`, and `event=update` / `event=end`. Rationale: correct headers are mandatory or pushes are silently dropped.
- [ ] Task 2.3. Implement HMAC verification and per-`gatewayId` rate limiting + replay protection (nonce window). Rationale: stateless relay must defend itself without an account database.
- [ ] Task 2.4. Implement structured logs that **never** record `ciphertext`, `nonce`, or `activityToken`; only `gatewayId`, payload size, APNs response code, and timing. Rationale: the relay's credibility is its privacy posture; logging is where that gets violated by accident.
- [ ] Task 2.5. Publish a reproducible build pipeline (e.g., GitHub Actions + signed releases + SBOM) so independent operators and skeptical users can verify the deployed binary matches source. Rationale: the relay being open source only matters if users can confirm the operator runs the same code.
- [ ] Task 2.6. Document the relay's self-host path so a user with their own Apple Developer account can replace the project's instance entirely. Rationale: this is the "BYO everything" escape hatch and must remain a first-class supported configuration.

### Phase 3 — Gateway (user-hosted, OSS, all the actual logic)

- [ ] Task 3.1. Build `printparty-gateway` as a single binary / Docker image. Default storage: embedded SQLite, no external dependencies. Optional: Postgres + Redis for larger setups, selected via config. Rationale: zero-friction "docker run" install is the make-or-break of self-hosted UX.
- [ ] Task 3.2. Define the gateway REST surface: `POST /v1/pair` (issue pairing token), `POST /v1/auth/exchange` (DH key exchange with iOS app), `GET/POST /v1/printers`, `POST /v1/printers/{id}/credentials`, `POST /v1/activities` (register an activity push token bound to `printJobId`), `GET /v1/printers/{id}/state`, `WS /v1/stream` (live in-app updates). Rationale: clean separation between pairing, control plane, and live data plane.
- [ ] Task 3.3. Implement the **E2EE encryptor**: for each outbound push, fetch the per-printer key, encrypt the `PrintJobState` JSON with ChaCha20-Poly1305 + random nonce, wrap in the `ContentState` envelope, HMAC-sign for the relay, POST to the relay's `/v1/push`. Rationale: this is the privacy guarantee in code form.
- [ ] Task 3.4. Implement the **update coalescer**: at most one APNs push per printer per ~30–60s, immediate on stage/error transitions, final state on completion; track per-activity push budget and back off gracefully. Rationale: ActivityKit budget enforcement and battery.
- [ ] Task 3.5. Provide a built-in local web UI for first-run setup, printer registration, pairing token / QR code display, log viewer, and "test push" tooling. Rationale: self-hosted users will need to debug; a good local UI is the difference between adoption and abandonment.
- [ ] Task 3.6. Implement gateway-side relay-failover: support `relay_url` config so users can point at the project's relay, their own relay, or a community-run relay. Rationale: don't bake project URLs into the binary.

### Phase 4 — Bambu A1 Mini Adapter

- [ ] Task 4.1. Define the `PrinterAdapter` interface in a shared `adapters/` library used by both the gateway and the bridge: `func start(config: AdapterConfig) -> AsyncStream<PrintJobState>` plus a config-validation hook. Rationale: this is the abstraction that makes the project a platform.
- [ ] Task 4.2. Implement `BambuCloudAdapter`: Bambu account login (email + password + email verification handling), MQTT subscriber to `device/<serial>/report` on the Bambu Cloud broker, refresh-token rotation. Rationale: works for any Bambu user without home network configuration; durable to Bambu's LAN tightening.
- [ ] Task 4.3. Implement `BambuLanAdapter`: MQTT over TLS to the printer itself (`bblp` + LAN access code, self-signed cert handling). Rationale: privacy-preserving and lower latency where network conditions permit.
- [ ] Task 4.4. Implement the shared `BambuTelemetry → PrintJobState` mapper. Handle delta updates, retain last full state, synthesize `jobId` boundaries from `gcode_state` transitions (IDLE → PREPARE/RUNNING starts; FINISH/FAILED ends). Rationale: Bambu's protocol does not provide clean job IDs; the gateway must derive them.
- [ ] Task 4.5. Add reconnection, exponential backoff, credential-refresh, and a `printerOffline` synthetic stage emitted when telemetry stops during an active job. Rationale: silent disconnects are the most common failure and the user must learn about them.

### Phase 5 — iOS Client ↔ Gateway Wiring

- [ ] Task 5.1. Implement the "Add Gateway" first-run flow: scan QR or enter URL + pairing token, perform X25519 DH, store shared secret in App Group Keychain. Rationale: must succeed before anything else works.
- [ ] Task 5.2. Implement Live Activity lifecycle: on detecting (via gateway WebSocket) that a print started, call `Activity.request(...)`, subscribe to `pushTokenUpdates`, POST every token (including rotations) to the gateway's `/v1/activities` bound to `printJobId`. On end event, call `Activity.end(...)`. Rationale: per-activity tokens are the only way to push, and they rotate.
- [ ] Task 5.3. Implement the in-app foreground WebSocket subscription to the gateway for live UI updates independent of APNs. Rationale: in-app responsiveness shouldn't be hostage to APNs throttling.
- [ ] Task 5.4. Implement multi-gateway support in the app: users with more than one self-hosted gateway (home + workshop, for example) can register multiple, each with its own derived keys. Rationale: real households have more than one location.

### Phase 6 — Optional Bridge (`printparty-bridge`)

- [ ] Task 6.1. Build the bridge as a small Go static binary (~10 MB). Outbound WSS to the user's gateway, authenticated by a bridge token issued via the gateway's web UI. Rationale: outbound-only design works behind CGNAT and restrictive home networks.
- [ ] Task 6.2. Bridge consumes the same `adapters/` library as the gateway, so the LAN-side adapter logic is identical. Rationale: code reuse and behavioral parity.
- [ ] Task 6.3. Distribute as: Docker image, Home Assistant add-on, Raspberry Pi install script. Rationale: meet users where they already self-host.

### Phase 7 — Reliability, Long Prints & Polish

- [ ] Task 7.1. Long-print handling: request maximum-duration Live Activities; when nearing TTL, gateway sends a regular notification with a "Resume tracking" deep link that requests a fresh activity from the app. Rationale: graceful UX for prints exceeding 8/12h.
- [ ] Task 7.2. Final-state guarantees: on `FINISH`/`FAILED`/`CANCELED`, send a single high-priority `event=end` push with terminal `ContentState` plus a regular notification with summary. Rationale: outcomes must reach the user even if the Live Activity already auto-dismissed.
- [ ] Task 7.3. Observability: gateway-side APNs-response telemetry (BadDeviceToken cleanup, ExpiredToken, throttle codes), per-printer push-budget metrics. Rationale: silent push failures are the #1 way these features rot in production.
- [ ] Task 7.4. Tests: contract tests for `BambuTelemetry → PrintJobState`, replay tests against recorded MQTT captures, snapshot tests for Live Activity views, end-to-end test against a real A1 Mini in CI staging, fuzz tests for the E2EE envelope decoder. Rationale: regressions in mapping or crypto code are silent and brand-damaging.

### Phase 8 — Second Adapter & Adapter Authoring Guide

- [ ] Task 8.1. Implement a second adapter (recommended: **OctoPrint** or **Moonraker/Klipper**) to prove the abstraction works across a fundamentally different transport. Rationale: locks in the `PrinterAdapter` contract before more vendors are added.
- [ ] Task 8.2. Publish an Adapter Authoring Guide and a template repository so external contributors can add printers (Prusa Connect, Creality Cloud, Anycubic, etc.). Rationale: third-party adapters are the long-term growth path.

### Phase 9 — "BYO Everything" Documentation

- [ ] Task 9.1. Document the path for a user with their own Apple Developer account to fork the iOS app under their own bundle ID, build it themselves, and run their own relay with their own APNs key. Rationale: this is the "zero dependency on the project" escape hatch and a key credibility signal for the OSS community.
- [ ] Task 9.2. Provide an `App.config.example` showing all the substitutions (bundle ID, team ID, relay URL) and a one-page checklist for what's required (paid Apple Developer membership, Xcode, APNs key). Rationale: makes the path discoverable rather than theoretical.

---

## Verification Criteria

- Starting a print on the A1 Mini causes a Live Activity to appear on the registered iPhone within **≤ 15 seconds**, with the iPhone on cellular and the user running only their own gateway.
- The Live Activity updates progress and ETA at least every **60 seconds**, and updates **immediately** (≤ 5s) on stage transitions.
- On finish/fail/cancel, an `event=end` push delivers the terminal state and a confirmation notification follows.
- The relay's structured logs, audited end-to-end across a print, contain **zero plaintext print data** — only `gatewayId`, payload size, APNs response codes, and timestamps.
- An independent third party can rebuild the relay from source and produce a binary byte-identical (or signature-verifiably equivalent) to the project's hosted deployment.
- A user can configure `relay_url` in their gateway to point at a self-hosted relay with a self-issued APNs key, and the system functions end-to-end with zero traffic to project-operated infrastructure.
- A second printer adapter (OctoPrint or Moonraker) can be added without modifying the iOS app, the widget, or the relay.
- All sensitive credentials (printer accounts, LAN codes, E2EE keys) are stored encrypted at rest on the gateway and never logged.
- Reinstalling the iOS app and re-pairing rotates all keys and immediately resumes working Live Activities for active prints.

---

## Potential Risks and Mitigations

1. **Apple changes APNs Live Activity terms or push budgets.** Could degrade or break the core feature.
   Mitigation: keep the relay tiny and easy to swap; lean on `Text(timerInterval:)` so we minimize push count; watch for budget changes in each iOS major.
2. **Bambu Lab breaks unofficial cloud MQTT access.** This has hurt similar projects before.
   Mitigation: ship both `BambuCloudAdapter` and `BambuLanAdapter`; the bridge can run either; community-watch upstream projects for early warning; document adapter migration as a first-class operation.
3. **8 / 12-hour Live Activity TTL vs multi-day prints.** Activity auto-dismisses mid-print.
   Mitigation: Phase 7 pre-expiry notification + "Resume tracking" deep link + guaranteed final-state push.
4. **Self-hosted gateway compromise.** Attacker gets printer credentials and that household's E2EE keys.
   Mitigation: at-rest encryption with an OS-keystore-derived KEK where available; document hardening; per-printer key scoping limits blast radius.
5. **Relay compromise.** Attacker can deny service or attempt replay.
   Mitigation: ciphertext is opaque so payload confidentiality is preserved; encrypted body includes a monotonic counter to defeat replay; relay is stateless and rebuildable in minutes.
6. **Per-activity APNs push token rotation.** A stale-token bug silently breaks updates.
   Mitigation: client must observe `pushTokenUpdates` (not just the initial token) and POST every rotation; gateway accepts updates idempotently.
7. **User runs the gateway off-network from the printer (e.g., gateway on a VPS, printer at home).**
   Mitigation: the optional bridge handles this with outbound WSS — no port-forwarding or public IP required.
8. **Onboarding friction kills adoption.** Self-hosting is inherently harder than SaaS.
   Mitigation: ship a one-command Docker install, a Home Assistant add-on, a Raspberry Pi script, and a polished local web UI. The gateway's first-run experience is a make-or-break investment.
9. **A1 Mini firmware tightening LAN mode** (precedent exists).
   Mitigation: cloud adapter is treated as the contract; LAN adapter is an optimization.
10. **Cost & sustainability of the project-operated relay.** Bandwidth and APNs throughput scale with active users.
    Mitigation: relay is intentionally tiny (likely runs on a $5–$10/mo VM for thousands of users); ask for community sponsorship; community-run alternative relays are explicitly supported via `relay_url`.

---

## Alternative Approaches Considered

1. **Pure SaaS** (project hosts everything). Rejected: contradicts the OSS / self-hosted-first goal and creates credential-storage liability.
2. **Pure self-hosted, no project relay**. Rejected for the mainstream path: requires every user to hold a paid Apple Developer account and run their own APNs-bound build. Retained as the Phase 9 "BYO everything" escape hatch.
3. **Plaintext payloads through the project relay.** Rejected: undermines the privacy posture that makes the architecture defensible. E2EE is what makes it honest to call the relay "stateless and project-blind."
4. **TestFlight-only distribution.** Rejected: 90-day expiry per build and 10,000-tester cap; unsuitable as a primary distribution channel.
5. **Federated / blockchain-style relay network.** Considered and rejected as overengineering for the problem. A simple `relay_url` config plus reproducible builds delivers the same trust properties with two orders of magnitude less complexity.
6. **Single-binary "all-in-one" (gateway + relay merged).** Rejected: confuses the trust boundary that is the whole point of the design. Keeping them as distinct services makes "the project sees nothing" provable from the deployment topology.

---

## Assumptions Made

- Target iOS 17.2+ for full server-pushed Live Activity feature set.
- The project is willing to maintain one Apple Developer account and one App Store listing, and to operate the relay as a small free service (or hand it off to a community operator).
- The Bambu A1 Mini's MQTT topic/payload format remains broadly compatible with community-documented behavior; if it diverges, only the `BambuCloud/LanAdapter` mapper changes.
- Users self-hosting the gateway have at minimum the ability to run a Docker container or a single binary on a Raspberry Pi, NAS, home server, or low-cost VPS.
- AGPLv3 for gateway and bridge is acceptable to the maintainer; MIT for iOS app and relay is acceptable. License choices can be revisited but the asymmetric split (copyleft on the data plane, permissive on the relay) is the recommended posture.
