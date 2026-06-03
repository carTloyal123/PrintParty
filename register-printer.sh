#!/bin/bash
#
# Register a Bambu Lab A1 Mini printer on the gateway.
#
# Edit the variables below, then run:  ./register-printer.sh
#

# ── Configuration ─────────────────────────────────────────────────
GATEWAY_URL="http://localhost:8080"

DISPLAY_NAME="A1 Mini"
MODEL_NAME="Bambu Lab A1 Mini"

# Your printer's LAN IP address (Settings → WLAN on the printer).
HOST="192.168.1.247"

# Your printer's serial number (Settings → General → Device info).
SERIAL="0300CA591700733"

# LAN access code (Settings → General → LAN Only Mode).
ACCESS_CODE="039c3628"
# ──────────────────────────────────────────────────────────────────

echo "Registering printer on gateway at $GATEWAY_URL..."
curl -s -X POST "$GATEWAY_URL/v1/printers" \
  -H 'Content-Type: application/json' \
  -d "{
    \"displayName\": \"$DISPLAY_NAME\",
    \"modelName\": \"$MODEL_NAME\",
    \"host\": \"$HOST\",
    \"serial\": \"$SERIAL\",
    \"accessCode\": \"$ACCESS_CODE\"
  }" | python3 -m json.tool

echo ""
echo "Done. Check the gateway logs for 'CONNACK ok'."
