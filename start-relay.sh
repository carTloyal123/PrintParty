#!/bin/bash
#
# Start the PrintParty Relay (APNs push forwarder)
#
# Edit the variables below, then run:  ./start-relay.sh
# Press Ctrl+C to stop cleanly.
#
# You need an APNs auth key (.p8) from Apple Developer portal:
#   https://developer.apple.com/account/resources/authkeys/list
#


# ── Configuration ─────────────────────────────────────────────────
# Path to your .p8 APNs auth key file (resolved relative to the project root).
export APNS_KEY_PATH="./AuthKey_ZN749C348S.p8"

# 10-character Key ID shown when you created the key.
export APNS_KEY_ID="ZN749C348S"

# Your Apple Developer Team ID.
export APNS_TEAM_ID="Z2Z9BCQBJN"

# Your app's bundle identifier.
export APNS_TOPIC="com.clengineering.PrintParty"

# "true" for development/debug builds, "false" for App Store / TestFlight.
export APNS_SANDBOX="true"

# Optional: override listen address and port.
# export HOST="0.0.0.0"
# export PORT="8090"
# ──────────────────────────────────────────────────────────────────

cd "$(dirname "$0")/relay" || exit 1

# Build first so we can run the binary directly (not via swift run)
# which gives us clean signal handling.
echo "Building relay..."
swift build --quiet 2>&1
if [ $? -ne 0 ]; then
    echo "Build failed."
    exit 1
fi

# Replace the shell process with the binary so Ctrl+C (SIGINT) goes
# directly to Vapor, which handles graceful shutdown internally.
# No trap needed — exec means there's no parent shell to interfere.
BINARY=".build/debug/printparty-relay"
exec "$BINARY"
