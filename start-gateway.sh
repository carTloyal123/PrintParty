#!/bin/bash
#
# Start the PrintParty Gateway
#
# Edit the variables below, then run:  ./start-gateway.sh
# Press Ctrl+C to stop cleanly.
#
# Options:
#   --clear-cache   Wipe all persisted state (printers, identity, pairings)
#                   before starting. Useful for a clean-slate test.
#

# ── Configuration ─────────────────────────────────────────────────
# URL of the relay that forwards APNs pushes. Leave empty to disable
# push notifications (WebSocket streaming still works).
export RELAY_URL="http://localhost:8090"

# Optional: override the gateway's listen address and port.
# export HOST="0.0.0.0"
# export PORT="8080"

# Optional: override the gateway display name shown in the iOS app.
# export GATEWAY_NAME="My PrintParty Gateway"
# ──────────────────────────────────────────────────────────────────

# Handle --clear-cache
DATA_DIR="${PRINTPARTY_DATA_DIR:-$HOME/.printparty}"
if [[ "$1" == "--clear-cache" ]]; then
    if [ -d "$DATA_DIR" ]; then
        echo "Clearing gateway cache at $DATA_DIR ..."
        echo "  Removing: printers.json, gateway-identity.json, gateway-pairings.json"
        rm -f "$DATA_DIR/printers.json"
        rm -f "$DATA_DIR/gateway-identity.json"
        rm -f "$DATA_DIR/gateway-pairings.json"
        echo "  Done. Gateway will start fresh (new identity, no printers, no pairings)."
        echo "  iOS devices will need to re-pair."
        echo ""
    else
        echo "No cache directory found at $DATA_DIR — nothing to clear."
        echo ""
    fi
fi

cd "$(dirname "$0")/gateway" || exit 1

# Build first so we can run the binary directly (not via swift run)
# which gives us clean signal handling.
echo "Building gateway..."
swift build --quiet 2>&1
if [ $? -ne 0 ]; then
    echo "Build failed."
    exit 1
fi

# Replace the shell process with the binary so Ctrl+C (SIGINT) goes
# directly to Vapor, which handles graceful shutdown internally.
# No trap needed — exec means there's no parent shell to interfere.
BINARY=".build/debug/printparty-gateway"
exec "$BINARY"
