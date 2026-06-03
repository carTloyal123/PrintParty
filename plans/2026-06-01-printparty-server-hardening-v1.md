# PrintParty Server Hardening Plan

## Objective

Identify and prioritize concrete hardening fixes across the Gateway and Relay server codebases to improve connection resilience, data integrity, operational robustness, security posture, and resource leak prevention.

---

## Priority 1 — Critical (Security / Data Loss)

### H-01: Gateway identity and keypair are ephemeral — pairings break on restart
**Files:** `gateway/Sources/PrintPartyGateway/Configure.swift:18`, `gateway/Sources/PrintPartyGateway/Pairing/PairingService.swift:50`
**Problem:** `gatewayId` is a new `UUID()` on every launch (line 18), and `gatewayPrivateKey` is a freshly generated `Curve25519.KeyAgreement.PrivateKey()` (line 50). Every restart invalidates all existing pairings and derived E2EE keys — iOS devices must re-pair and any in-flight Live Activities lose E2EE.
**Rationale:** This is the highest-priority fix because it makes the E2EE system fragile in production; an unplanned gateway restart silently breaks all encryption without any user-visible error.

- [ ] 1a. Persist `gatewayId` and the X25519 private key raw bytes to `~/.printparty/gateway-identity.json` (or a separate keyfile) on first run.
- [ ] 1b. Load the persisted identity at startup in `Configure.swift`; only generate a new one if the file is missing.
- [ ] 1c. Use the same `PrinterStore`-style atomic write pattern for crash safety.

### H-02: APNs `.p8` signing key checked into source control
**Files:** `relay/AuthKey_ZN749C348S.p8`
**Problem:** The Apple private signing key is committed to the repository. Anyone with repo access can impersonate the relay for APNs.
**Rationale:** This is a credential leak — the key grants the ability to send push notifications to all app users.

- [ ] 2a. Add `*.p8` to `.gitignore` and remove the key from git history (e.g., `git filter-repo`).
- [ ] 2b. Document the expected key path in a `.env.example` file.

### H-03: Pairing code exposed via unauthenticated GET endpoint
**Files:** `gateway/Sources/PrintPartyGateway/Routes/PairingRoutes.swift:18,57-61`
**Problem:** `GET /v1/pair/code` returns the active pairing code to any caller on the network with no authentication. An attacker on the LAN can poll this endpoint, obtain the code, and complete a pairing handshake to derive the shared E2EE key.
**Rationale:** Defeats the purpose of the pairing code as a shared secret.

- [ ] 3a. Gate this endpoint behind a development-only flag (e.g., only enable when `VAPOR_ENV=development`), or remove it entirely.
- [ ] 3b. Alternatively, require a local admin bearer token set at gateway startup.

### H-04: No authentication on any gateway REST endpoint
**Files:** `gateway/Sources/PrintPartyGateway/Routes/PrinterRoutes.swift:14-20`, `gateway/Sources/PrintPartyGateway/Routes/StreamRoutes.swift:17`
**Problem:** `POST /v1/printers`, `POST /v1/activities`, `GET /v1/stream`, and all other endpoints accept requests from any device on the network. An attacker can register rogue printers, register push tokens, or eavesdrop on WebSocket telemetry.
**Rationale:** LAN-accessible services without auth are vulnerable to any device on the same Wi-Fi (guests, IoT, compromised hosts).

- [ ] 4a. Introduce a Vapor `Middleware` that validates a bearer token issued during the pairing handshake.
- [ ] 4b. Exempt `/healthz` and `POST /v1/pair` from the auth middleware (those are pre-auth by design).
- [ ] 4c. Store valid device tokens in `PairingService.pairings` and validate against them.

### H-05: No authentication on relay push endpoint
**Files:** `relay/Sources/PrintPartyRelay/Routes/PushRoutes.swift:18`
**Problem:** `POST /v1/push` is unauthenticated. Any caller can send arbitrary push notifications through the relay to any device token.
**Rationale:** Even though content is E2EE, an attacker can spam push notifications or exhaust APNs rate limits.

- [ ] 5a. Add a shared API key or mTLS requirement between gateway and relay.
- [ ] 5b. Validate incoming `deviceToken` format (hex string, 64 chars) to reject malformed requests early.

### H-06: Dead `encrypt()` method silently produces undecryptable ciphertext
**Files:** `gateway/Sources/PrintPartyGateway/Crypto/ContentStateEncryptor.swift:34-53`
**Problem:** The `encrypt()` method on line 51 emits `sealed.ciphertext` without the Poly1305 authentication tag. If accidentally called instead of `encryptCombined()`, the iOS side will fail to decrypt — silently, with no error surfaced to the user.
**Rationale:** A latent defect that will produce silent data corruption if any code path calls the wrong method.

- [ ] 6a. Delete the `encrypt()` method entirely, or mark it `@available(*, unavailable, message: "Use encryptCombined()")`.
- [ ] 6b. Rename `encryptCombined()` to just `encrypt()` to become the single correct API.

---

## Priority 2 — High (Connection Resilience / Resource Leaks)

### H-07: Reconnect task leaks if `connectPrinter` throws after sleep
**Files:** `gateway/Sources/PrintPartyGateway/Printers/PrinterService.swift:205-211`
**Problem:** In `scheduleReconnect`, the `Task` captures `[weak self]` but after `connectPrinter` fails (line 210), the flow falls through without rescheduling. The printer stays offline permanently until the next external event. The task reference in `reconnectTasks[printerId]` is never cleaned up.
**Rationale:** After a transient network failure, the gateway will never auto-recover for that printer.

- [ ] 7a. Wrap `connectPrinter` in a do/catch inside the reconnect task; on failure, call `scheduleReconnect` again to continue the backoff chain.
- [ ] 7b. Add a `defer { reconnectTasks[printerId] = nil }` inside the task closure to clean up the completed task reference.

### H-08: Fire-and-forget `pushall` retry task is never tracked or cancelled
**Files:** `gateway/Sources/PrintPartyGateway/Printers/PrinterService.swift:155-158`
**Problem:** The 2-second delayed `pushall` retry creates an untracked `Task`. If the printer is unregistered within those 2 seconds, the task still fires and publishes to a potentially recycled or nil MQTT client.
**Rationale:** Minor resource leak and potential for confusing log messages; could also publish to a wrong client if the printer ID is re-registered quickly.

- [ ] 8a. Store this task in a dictionary (or per-printer state struct) and cancel it during `unregister()` and `stop()`.
- [ ] 8b. Guard the task body with a check that the printer is still registered.

### H-09: Keepalive task captures `self` strongly via closure
**Files:** `gateway/Sources/PrintPartyGateway/MQTT/NIOMQTTClient.swift:165-179`
**Problem:** The keepalive `Task` on lines 165-179 references `self` (the `NIOMQTTClient`) directly — not `[weak self]`. Since `NIOMQTTClient` is stored in `PrinterService.mqttClients`, and the task runs indefinitely, this creates a retain cycle: `PrinterService → NIOMQTTClient → Task → NIOMQTTClient`.
**Rationale:** Prevents deallocation of `NIOMQTTClient` after unregister if `teardown()` is not called.

- [ ] 9a. Change the keepalive task to use `[weak self]` and break out of the loop if `self` is nil.

### H-10: NIO channel close during `teardown()` does not await completion
**Files:** `gateway/Sources/PrintPartyGateway/MQTT/NIOMQTTClient.swift:222`
**Problem:** `ch.close(promise: nil)` fires and forgets the close. In a rapid reconnect cycle (teardown → start), the old channel's close may not complete before the new channel opens, leading to transient resource contention on the socket.
**Rationale:** Could cause "address already in use" errors on rapid reconnect cycles (though unlikely with outbound connections).

- [ ] 10a. Use `try? await ch.close()` or at minimum attach a promise to log close failures.

### H-11: `try!` crash in NIO TLS handler construction
**Files:** `gateway/Sources/PrintPartyGateway/MQTT/NIOMQTTClient.swift:147`
**Problem:** `try! NIOSSLClientHandler(...)` will crash the entire process if TLS context creation fails (e.g., invalid configuration). This is inside a `channelInitializer` closure where the crash is unrecoverable.
**Rationale:** A defensive `do/catch` with a proper error propagation would prevent the gateway from crashing.

- [ ] 11a. Replace `try!` with proper error handling inside the `channelInitializer`, returning a failed future on error.

### H-12: WebSocket send errors are silently ignored
**Files:** `gateway/Sources/PrintPartyGateway/Printers/PrinterService.swift:258`
**Problem:** `ws.send(json)` does not check the result or attach an error handler. If the WebSocket write buffer is full or the connection is half-closed, the send silently fails. The `isClosed` check on line 255 only catches fully-closed sockets, not ones in an error state.
**Rationale:** Clients may silently stop receiving updates without the server knowing.

- [ ] 12a. Use `ws.send(json).whenFailure { ... }` to log write failures and proactively remove broken sockets.

### H-13: No WebSocket ping/pong keepalive
**Files:** `gateway/Sources/PrintPartyGateway/Routes/StreamRoutes.swift:21-29`
**Problem:** The WebSocket connection has no ping/pong mechanism. If a client's network drops silently (e.g., phone goes to sleep), the server won't detect the dead connection until the next `broadcastState` call finds `isClosed == true`.
**Rationale:** Dead WebSocket connections accumulate in `wsClients`, wasting memory and broadcast cycles.

- [ ] 13a. Configure WebSocket ping interval when creating the WebSocket handler.
- [ ] 13b. Set an `onPong` timeout to proactively close unresponsive connections.

---

## Priority 3 — Medium (Data Integrity / Operational Robustness)

### H-14: PrinterStore writes are not protected against concurrent access
**Files:** `gateway/Sources/PrintPartyGateway/Printers/PrinterStore.swift:44-51`
**Problem:** `PrinterStore` is a plain `struct` (not an actor). While it's only called from the `PrinterService` actor today, `save()` does synchronous blocking I/O inside the actor, and nothing prevents future callers from using it concurrently. The `save()` call on line 101 (`unregister`) and line 87 (`register`) could theoretically interleave if the actor is reentered (e.g., via `await` suspension points).
**Rationale:** Defensive measure to prevent data corruption if the calling patterns evolve.

- [ ] 14a. Make `PrinterStore` an actor, or document that it must only be called from `PrinterService`'s actor context.
- [ ] 14b. Consider debouncing saves — currently every register/unregister triggers an immediate write.

### H-15: Pairings are in-memory only — lost on restart
**Files:** `gateway/Sources/PrintPartyGateway/Pairing/PairingService.swift:43`
**Problem:** `pairings: [String: Pairing]` is in-memory only (comment on line 9-10 acknowledges this). Combined with H-01 (ephemeral keypair), every restart requires all iOS devices to re-pair.
**Rationale:** This is acknowledged as a known limitation (planned for M6+), but it compounds with H-01.

- [ ] 15a. Persist the `pairings` dictionary alongside the gateway identity (H-01).
- [ ] 15b. On load, derive `SymmetricKey` from the persisted shared secret or store the derived key directly.

### H-16: No graceful MQTT disconnect during Vapor application shutdown
**Files:** `gateway/Sources/PrintPartyGateway/Printers/PrinterService.swift` (no shutdown hook), `gateway/Sources/PrintPartyGateway/Configure.swift` (no lifecycle handler)
**Problem:** When the Vapor app shuts down (SIGINT/SIGTERM), there is no `LifecycleHandler` or shutdown hook that iterates `mqttClients` and calls `stop()`. MQTT connections are dropped abruptly, which may cause the broker (printer) to hold the session for the keepalive timeout.
**Rationale:** Clean MQTT DISCONNECT packets help the printer release the session immediately.

- [ ] 16a. Add a Vapor `LifecycleHandler` that iterates all MQTT clients and calls `await client.stop(reason: "shutdown")`.
- [ ] 16b. Cancel all reconnect tasks during shutdown.
- [ ] 16c. Close all WebSocket connections gracefully.

### H-17: Relay does not shut down the APNs HTTP/2 client on app termination
**Files:** `relay/Sources/PrintPartyRelay/Configure.swift:45-50`
**Problem:** The `APNSClient` is stored in `app.storage` but never explicitly shut down. The HTTP/2 connection pool may linger, causing a delay on SIGTERM.
**Rationale:** Clean shutdown prevents resource warnings and ensures pending pushes are flushed.

- [ ] 17a. Add a Vapor `LifecycleHandler` that calls `apnsClient.shutdown()` (or equivalent) during `willStop`.

### H-18: `pushToRelay` sends to all tokens sequentially, not concurrently
**Files:** `gateway/Sources/PrintPartyGateway/Printers/PrinterService.swift:292-328`
**Problem:** The `for token in tokens` loop (line 292) sends relay requests one at a time. With multiple paired devices, each with a 10-second timeout (line 317), a single unresponsive relay could block telemetry updates for up to `N * 10` seconds.
**Rationale:** Could cause telemetry delivery delays during relay degradation.

- [ ] 18a. Use `withTaskGroup` to send relay requests concurrently.
- [ ] 18b. Add per-token circuit breaker or rate limiting to avoid hammering a failing relay.

### H-19: No rate limiting on pairing attempts
**Files:** `gateway/Sources/PrintPartyGateway/Routes/PairingRoutes.swift:40-47`
**Problem:** An attacker can brute-force `POST /v1/pair` with all 2^40 possible codes (though the 5-minute expiry helps). There is no rate limiting or lockout mechanism.
**Rationale:** 40 bits of entropy is borderline; rate limiting adds defense in depth.

- [ ] 19a. Add a rate limiter (e.g., max 10 attempts per minute per IP) to the pairing endpoint.
- [ ] 19b. Consider logging failed attempts and temporarily extending the backoff.

---

## Priority 4 — Low (Logging / Observability / Code Quality)

### H-20: Pairing code logged in plaintext at INFO level
**Files:** `gateway/Sources/PrintPartyGateway/Pairing/PairingService.swift:76,85`, `gateway/Sources/PrintPartyGateway/Configure.swift:57`
**Problem:** The pairing code is logged on rotation (lines 76, 85) and printed in the startup banner (line 57). In a production deployment with centralized logging, this exposes the pairing secret.
**Rationale:** Low risk for a LAN-only service, but a hygiene issue for production logging pipelines.

- [ ] 20a. Log pairing codes at `DEBUG` or `TRACE` level instead of `INFO`/`NOTICE`.
- [ ] 20b. Redact or mask codes in the startup banner for non-development environments.

### H-21: Printer access codes stored and logged in plaintext
**Files:** `gateway/Sources/PrintPartyGateway/Printers/PrinterService.swift:21` (struct field), `gateway/Sources/PrintPartyGateway/Printers/PrinterStore.swift:47` (persisted as JSON)
**Problem:** `PrinterConfig.accessCode` is stored as a plaintext string in both memory and the JSON file on disk. The entire struct is `Codable`, so the access code is written to `~/.printparty/printers.json` in cleartext.
**Rationale:** Anyone with read access to the data directory can extract Bambu printer access codes.

- [ ] 21a. Encrypt the access code at rest using a machine-level key or OS keychain.
- [ ] 21b. At minimum, restrict file permissions on `printers.json` to owner-only (0600).

### H-22: Missing `DELETE /v1/printers/:id` endpoint
**Files:** `gateway/Sources/PrintPartyGateway/Routes/PrinterRoutes.swift:14-20`
**Problem:** There is no HTTP endpoint to unregister a printer. The `unregister()` method exists in `PrinterService` (line 91) but is not exposed via any route.
**Rationale:** Operators must restart the gateway and delete `printers.json` manually to remove a printer.

- [ ] 22a. Add `DELETE /v1/printers/:printerId` route that calls `printerService.unregister()`.

### H-23: `AnyCodable` decode order may misclassify `Bool` as `Int`
**Files:** `relay/Sources/PrintPartyRelay/Routes/PushRoutes.swift:89-107`
**Problem:** JSON booleans are decoded as `Int` (line 98) before `Bool` is tried (line 101). In Swift's `JSONDecoder`, `true`/`false` can successfully decode as `Int` (1/0), so booleans in the content-state may be silently converted to integers.
**Rationale:** Since the relay is a pass-through and the content is E2EE, this only affects the envelope metadata — but it's a correctness issue if plaintext fallback is used.

- [ ] 23a. Reorder the decode attempts: try `Bool` before `Int` in the `AnyCodable` initializer.

### H-24: Health endpoint lacks printer connection status details
**Files:** `gateway/Sources/PrintPartyGateway/Routes/HealthRoutes.swift:21-29`
**Problem:** `/healthz` returns a static `"ok"` regardless of whether any printers are connected or all MQTT connections are down.
**Rationale:** Makes it harder to monitor gateway health in production.

- [ ] 24a. Add a `printers` field with per-printer connection status (connected/offline/reconnecting).
- [ ] 24b. Return HTTP 503 if all printers are offline (for load balancer health checks).

---

## Verification Criteria

- All persisted credentials (gateway keypair, printer access codes) survive a gateway restart without requiring re-pairing
- MQTT reconnect recovers from all failure modes: network drop, DNS failure, printer reboot, and `connectPrinter` exceptions
- Shutting down the gateway with SIGTERM sends MQTT DISCONNECT to all printers and closes all WebSockets within 5 seconds
- The `encrypt()` method is removed or made uncallable
- No `try!` crash sites remain in production code paths
- Relay rejects unauthenticated requests
- `GET /v1/pair/code` is gated behind a development-only check
- WebSocket dead connections are detected within 30 seconds via ping/pong
- All untracked `Task` instances are stored and cancellable

## Potential Risks and Mitigations

1. **Persisting the X25519 private key introduces a new attack surface (H-01)**
   Mitigation: Use file permissions (0600) and consider OS keychain integration on macOS.

2. **Adding auth middleware (H-04) may break existing iOS clients**
   Mitigation: Version the API (`/v2/`) or add a grace period where unauthenticated requests are logged but not rejected.

3. **Concurrent relay pushes (H-18) may overwhelm a single relay instance**
   Mitigation: Cap concurrency with `withTaskGroup` using a bounded task group or semaphore.

4. **Reordering AnyCodable (H-23) may change behavior for existing relay deployments**
   Mitigation: Since content is E2EE and opaque to the relay, the risk is minimal — only non-E2EE fallback is affected.
