# Remove Redundant 30s LAN Polling from GatewayStreamClient

## Objective

Remove the periodic 30-second LAN probe timer from `GatewayStreamClient`. The `NWPathMonitor` already detects network changes and triggers a LAN probe -- the polling loop is redundant and wastes battery.

## Implementation Plan

### File: `PrintParty/Core/Net/GatewayStreamClient.swift`

- [ ] **Remove the eager probe on relay connect (lines 237-240)**
  Delete these 4 lines from the `receiveLoop` success path:
  ```swift
                        // If we connected via relay, start probing LAN in background.
                        if mode == .relay {
                            self.probeLANInBackground()
                        }
  ```
  The `NWPathMonitor` handler at line 142-144 already calls `probeLANInBackground()` when the network path changes while on relay. No need to also kick off a probe the instant we connect.

- [ ] **Remove the 30s re-scheduling loop inside `probeLANInBackground()` (lines 327-337)**
  Replace the `catch` block:
  ```swift
            } catch {
                // LAN not reachable — schedule another probe later.
                Self.log.info("GatewayStream: LAN probe failed — staying on relay")
                guard self.started, self.connectionMode == .relay else { return }
                probeWs.cancel(with: .goingAway, reason: nil)
                // Schedule another probe in 30s.
                self.lanProbeTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard let self else { return }
                    self.probeLANInBackground()
                }
            }
  ```
  With:
  ```swift
            } catch {
                // LAN not reachable — stay on relay. NWPathMonitor will
                // trigger another probe if the network changes again.
                Self.log.info("GatewayStream: LAN probe failed — staying on relay")
                probeWs.cancel(with: .goingAway, reason: nil)
            }
  ```

- [ ] **Remove the initial 10s sleep in `probeLANInBackground()` (lines 279-281)**
  Delete these lines:
  ```swift
            // Wait before probing to avoid rapid-fire attempts.
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.started, self.connectionMode == .relay else { return }
  ```
  The `NWPathMonitor` already debounces network changes. When it fires, we should probe promptly.

- [ ] **Update the MARK comment (line 270-273)**
  Change from:
  ```swift
  // MARK: - LAN probe (while on relay)

  /// Periodically probe the LAN WebSocket while connected via relay.
  /// If the LAN becomes reachable, switch back to it.
  ```
  To:
  ```swift
  // MARK: - LAN probe (triggered by NWPathMonitor while on relay)

  /// Probe the LAN WebSocket when a network change is detected while on relay.
  /// If the LAN is reachable, tear down the relay and switch back to LAN.
  ```

## Rationale

The `NWPathMonitor` (`handlePathUpdate` at line 122) is the correct trigger for LAN probes:
- **Line 130-141**: Network goes from unsatisfied to satisfied -- tears down and does a full `connect()` (LAN-first).  
- **Line 142-144**: Network stays satisfied but path changes (e.g., switched Wi-Fi networks) while on relay -- calls `probeLANInBackground()`.

The 30-second polling adds nothing because if the network path hasn't changed, there's no reason to expect the gateway to suddenly appear on LAN. The `NWPathMonitor` covers all the meaningful transitions.
