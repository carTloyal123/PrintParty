#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$PROJECT_DIR/PrintParty.xcodeproj"
SCHEME="PrintParty"
BUNDLE_ID="com.clengineering.PrintParty"
CONFIGURATION="Debug"
DERIVED_DATA="$PROJECT_DIR/.build-derived-data"
BUILD_TIMEOUT=${BUILD_TIMEOUT:-120}

# ── Colours ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { printf "${CYAN}%s${RESET}\n" "$*"; }
success() { printf "${GREEN}%s${RESET}\n" "$*"; }
error()   { printf "${RED}%s${RESET}\n" "$*" >&2; }
header()  { printf "${BOLD}${YELLOW}%s${RESET}\n" "$*"; }

# ── Parse flags ──────────────────────────────────────────────────────
VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=true ;;
        -h|--help)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Builds, installs, and launches PrintParty on a device or simulator."
            echo ""
            echo "Options:"
            echo "  -v, --verbose   Show full xcodebuild output (no -quiet)"
            echo "  -h, --help      Show this help"
            echo ""
            echo "Environment:"
            echo "  BUILD_TIMEOUT   Build timeout in seconds (default: 120)"
            exit 0
            ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════
#  Gather all destinations (physical devices + simulators)
# ══════════════════════════════════════════════════════════════════════

info "Scanning for devices and simulators..."
echo ""

IDX=1
ENTRIES=()   # Each entry: "type|udid|display_name"

# ── Physical devices (devicectl writes JSON to a file, not stdout) ───
TMPJSON=$(mktemp /tmp/devicectl.XXXXXX.json)
trap "rm -f '$TMPJSON'" EXIT

xcrun devicectl list devices -j "$TMPJSON" >/dev/null 2>&1 || true

PHYSICAL_LINES=""
if [ -s "$TMPJSON" ]; then
    PHYSICAL_LINES=$(python3 -c "
import json, sys
with open('$TMPJSON') as f:
    data = json.load(f)
devices = data.get('result', {}).get('devices', [])
for d in devices:
    platform = d.get('hardwareProperties', {}).get('platform', '')
    if platform != 'iOS':
        continue
    name  = d.get('deviceProperties', {}).get('name', 'Unknown')
    osver = d.get('deviceProperties', {}).get('osVersionNumber', '?')
    ident = d.get('identifier', '')
    model = d.get('hardwareProperties', {}).get('marketingName', '')
    print(f'{name}|{model}|iOS {osver}|{ident}')
" 2>/dev/null || true)
fi

if [ -n "$PHYSICAL_LINES" ]; then
    header "Physical Devices"
    while IFS= read -r line; do
        NAME=$(echo "$line" | cut -d'|' -f1)
        MODEL=$(echo "$line" | cut -d'|' -f2)
        OSVER=$(echo "$line" | cut -d'|' -f3)
        UDID=$(echo "$line" | cut -d'|' -f4)
        printf "  ${BOLD}%3d)${RESET}  %s  ${DIM}(%s, %s)${RESET}\n" "$IDX" "$NAME" "$MODEL" "$OSVER"
        ENTRIES+=("physical|$UDID|$NAME")
        IDX=$((IDX + 1))
    done <<< "$PHYSICAL_LINES"
    echo ""
fi

# ── Simulators ───────────────────────────────────────────────────────
SIM_LINES=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in sorted(data['devices'].items()):
    if 'iOS' not in runtime:
        continue
    version = runtime.replace('com.apple.CoreSimulator.SimRuntime.iOS-', 'iOS ').replace('-', '.')
    for d in sorted(devices, key=lambda x: x['name']):
        if d.get('isAvailable'):
            print(f\"{d['name']}|{version}|{d['udid']}\")
" 2>/dev/null || true)

if [ -n "$SIM_LINES" ]; then
    header "Simulators"
    while IFS= read -r line; do
        NAME=$(echo "$line" | cut -d'|' -f1)
        OSVER=$(echo "$line" | cut -d'|' -f2)
        UDID=$(echo "$line" | cut -d'|' -f3)
        printf "  ${BOLD}%3d)${RESET}  %s  ${DIM}(%s)${RESET}\n" "$IDX" "$NAME" "$OSVER"
        ENTRIES+=("simulator|$UDID|$NAME")
        IDX=$((IDX + 1))
    done <<< "$SIM_LINES"
    echo ""
fi

# ── Validate we found something ──────────────────────────────────────
TOTAL=${#ENTRIES[@]}

if [ "$TOTAL" -eq 0 ]; then
    error "No devices or simulators found."
    error "Connect a device or create a simulator in Xcode > Settings > Platforms."
    exit 1
fi

# ── Prompt ───────────────────────────────────────────────────────────
printf "${BOLD}Select a destination [1-%s]: ${RESET}" "$TOTAL"
read -r CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$TOTAL" ]; then
    error "Invalid selection."
    exit 1
fi

SELECTED="${ENTRIES[$((CHOICE - 1))]}"
DEST_TYPE=$(echo "$SELECTED" | cut -d'|' -f1)
DEST_UDID=$(echo "$SELECTED" | cut -d'|' -f2)
DEST_NAME=$(echo "$SELECTED" | cut -d'|' -f3)

echo ""
info "Selected: $DEST_NAME ($DEST_TYPE, $DEST_UDID)"
echo ""

# ══════════════════════════════════════════════════════════════════════
#  Build
# ══════════════════════════════════════════════════════════════════════

info "Building $SCHEME ($CONFIGURATION) for $DEST_NAME..."
if ! $VERBOSE; then
    info "(pass -v for full build output)"
fi
echo ""

BUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "id=$DEST_UDID"
    -derivedDataPath "$DERIVED_DATA"
    -allowProvisioningUpdates
)

if ! $VERBOSE; then
    BUILD_ARGS+=(-quiet)
fi

BUILD_ARGS+=(build)

# Unlock the login keychain so codesign can access signing identities.
# Only needed for physical-device builds (simulator uses ad-hoc signing).
# Set KEYCHAIN_PASSWORD in your env to skip the interactive prompt.
if [ "$DEST_TYPE" = "physical" ]; then
    LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
        security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$LOGIN_KEYCHAIN" \
            || error "Failed to unlock keychain with KEYCHAIN_PASSWORD."
    else
        info "Unlocking login keychain for codesigning..."
        if ! security unlock-keychain "$LOGIN_KEYCHAIN"; then
            error "Could not unlock the login keychain."
            error "Set KEYCHAIN_PASSWORD in your environment or unlock it manually."
            exit 1
        fi
    fi
fi

# Pick a timeout command. GNU coreutils ships `timeout`; on systems without it
# (default macOS) we fall back to running xcodebuild directly.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout ${BUILD_TIMEOUT}"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout ${BUILD_TIMEOUT}"
fi

BUILD_EXIT=0
START_TIME=$SECONDS
if [ -n "$TIMEOUT_CMD" ]; then
    $TIMEOUT_CMD xcodebuild "${BUILD_ARGS[@]}" || BUILD_EXIT=$?
else
    xcodebuild "${BUILD_ARGS[@]}" || BUILD_EXIT=$?
fi
ELAPSED=$((SECONDS - START_TIME))

if [ "$BUILD_EXIT" -eq 124 ]; then
    echo ""
    error "Build timed out after ${BUILD_TIMEOUT}s."
    exit 124
elif [ "$BUILD_EXIT" -ne 0 ]; then
    echo ""
    error "Build failed (exit code $BUILD_EXIT)."
    if ! $VERBOSE; then
        error "Re-run with -v to see full build output."
    fi
    exit "$BUILD_EXIT"
fi

success "Build succeeded. (${ELAPSED}s)"
echo ""

# ══════════════════════════════════════════════════════════════════════
#  Install & Launch
# ══════════════════════════════════════════════════════════════════════

if [ "$DEST_TYPE" = "simulator" ]; then
    # ── Locate .app ──────────────────────────────────────────────────
    APP_PATH=$(find "$DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator" \
        -name "*.app" -maxdepth 1 2>/dev/null | head -1)

    if [ -z "$APP_PATH" ]; then
        error "Could not find the built .app bundle."
        exit 1
    fi

    # ── Boot simulator if needed ─────────────────────────────────────
    STATE=$(xcrun simctl list devices -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for rt, devs in data['devices'].items():
    for d in devs:
        if d['udid'] == '$DEST_UDID':
            print(d['state'])
            sys.exit()
")

    if [ "$STATE" != "Booted" ]; then
        info "Booting simulator..."
        xcrun simctl boot "$DEST_UDID" 2>/dev/null || true
    fi

    open -a Simulator --args -CurrentDeviceUDID "$DEST_UDID"

    info "Installing $SCHEME on $DEST_NAME..."
    xcrun simctl install "$DEST_UDID" "$APP_PATH"

    info "Launching $SCHEME..."
    xcrun simctl launch "$DEST_UDID" "$BUNDLE_ID"

else
    # ── Physical device ──────────────────────────────────────────────
    APP_PATH=$(find "$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos" \
        -name "*.app" -maxdepth 1 2>/dev/null | head -1)

    if [ -z "$APP_PATH" ]; then
        error "Could not find the built .app bundle."
        exit 1
    fi

    info "Installing $SCHEME on $DEST_NAME..."
    xcrun devicectl device install app --device "$DEST_UDID" "$APP_PATH"

    success "Installed."
    echo ""

    info "Launching $SCHEME on $DEST_NAME..."
    xcrun devicectl device process launch --device "$DEST_UDID" "$BUNDLE_ID"
fi

success "Done! $SCHEME is running on $DEST_NAME."
