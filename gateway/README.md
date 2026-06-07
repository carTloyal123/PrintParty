# PrintParty Gateway

Self-hosted gateway that bridges your 3D printers to the PrintParty iOS app.

## Running

```bash
# Native (macOS/Linux)
swift run printparty-gateway serve --hostname 0.0.0.0 --port 8080

# Docker (no relay needed for LAN use — see docker-compose.yml)
RELAY_URL= docker compose up gateway
```

On startup the gateway prints a pairing code and a scannable QR to the logs
(`docker compose logs gateway`).

## Pairing the iOS app

Three ways, in order of convenience:

1. **Auto-discovery (mDNS)** — the gateway advertises `_printparty._tcp` on the
   LAN and shows up under *Nearby Gateways* in the app. You still enter/scan the
   pairing code (discovery finds the gateway; the code authorizes the device).
2. **QR code** — scan the QR from the logs; it carries the URL **and** code, so
   pairing is zero-typing.
3. **Manual** — type the gateway URL + the 8-character code.

### Reaching the gateway behind Docker

Inside a bridge-network container the gateway only sees its container IP
(`172.x`), which a phone can't reach. Set **`ADVERTISE_HOST`** to the host
machine's LAN IP (e.g. `192.168.1.42`) so the QR and mDNS A-record point at a
reachable address. For mDNS auto-discovery from a container you also need
`network_mode: host` (Linux only — not Docker Desktop). See `docker-compose.yml`.

## Troubleshooting

### `mDNS: multicast send failed … auto-discovery is unavailable`

The gateway couldn't send multicast, so it falls back to QR / manual pairing
(both unaffected). Common causes:

- **macOS Local Network permission.** macOS 15+ gates multicast behind the
  *Local Network* privacy permission (System Settings → Privacy & Security →
  Local Network). A signed app gets a prompt; an **unsigned binary run from
  Terminal often cannot be granted it** (there's no stable identity to attach
  the grant to), so auto-discovery won't work in that setup — this is a
  dev-only quirk. **A Linux container has no such gate.** To validate discovery,
  run the gateway on a Linux host (Pi/NAS/server) with `network_mode: host`, or
  ship it as a signed macOS app. (`ping 224.0.0.251` reaching LAN hosts confirms
  the network itself is fine — the block is per-process.)
- **VPN / firewall** blocking multicast on the LAN.
- **Docker bridge networking** — multicast can't cross it; use `network_mode: host`.

QR and manual pairing keep working in all of these cases.
