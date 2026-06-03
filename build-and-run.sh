#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$PROJECT_DIR/PrintParty.xcodeproj"
SCHEME="PrintParty"
BUNDLE_ID="com.clengineering.PrintParty"
CONFIGURATION="Debug"
DERIVED_DATA="$PROJECT_DIR/.build-derived-data"
BUILD_TIMEOUT=${BUILD_TIMEOUT:-180}

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
warn()    { printf "${YELLOW}%s${RESET}\n" "$*"; }

# ── Parse flags ──────────────────────────────────────────────────────
VERBOSE=false
SKIP_CLEAN=false
for arg in "$@"; do
    case "$arg" in
        -v|--verbose)     VERBOSE=true ;;
        --no-clean)       SKIP_CLEAN=true ;;
        -h|--help)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Builds, installs, and launches PrintParty on a device or simulator."
            echo "By default, kills stale build services and cleans caches before every"
            echo "build to avoid the Xcode 26 SWBBuildService hang."
            echo ""
            echo "Options:"
            echo "  -v, --verbose   Show full xcodebuild output (no -quiet)"
            echo "  --no-clean      Skip the pre-build clean (faster, but may hang)"
            echo "  -h, --help      Show this help"
            echo ""
            echo "Environment:"
            echo "  BUILD_TIMEOUT   Build timeout in seconds (default: 180)"
            exit 0
            ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════
#  Pre-build clean (default: always, to avoid SWBBuildService hangs)
# ══════════════════════════════════════════════════════════════════════

if ! $SKIP_CLEAN; then
    info "Cleaning build environment..."

    # Kill any lingering build services that may be deadlocked
    pkill -9 -f 'xcodebuild' 2>/dev/null || true
    pkill -9 -f 'SWBBuildService' 2>/dev/null || true
    pkill -9 -f 'XCBBuildService' 2>/dev/null || true
    sleep 1

    # Wipe derived data and Clang module cache
    rm -rf "$DERIVED_DATA"
    rm -rf "$(getconf DARWIN_USER_CACHE_DIR)org.llvm.clang" 2>/dev/null || true
    rm -rf ~/Library/Developer/Xcode/DerivedData/PrintParty-* 2>/dev/null || true

    success "Clean."
    echo ""
fi

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
    COMPILATION_CACHING_ENABLED=YES
)

if ! $VERBOSE; then
    BUILD_ARGS+=(-quiet)
fi

BUILD_ARGS+=(build)

# Unlock the login keychain so codesign can access signing identities.
timeout 5 security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true

# ── NOTE: Xcode 26 SWBBuildService deadlock ──────────────────────────
# SWBBuildService has a mach-port deadlock that can cause builds to
# hang indefinitely at the "ExecuteExternalTool clang" step.
# This is a known Xcode 26 bug that cannot be worked around externally.
# The timeout below will catch it and give a clear error message.
# The build reliably works from interactive terminals — if it hangs
# from scripts/CI, re-run interactively.
BUILD_LOG=$(mktemp /tmp/xcodebuild-log.XXXXXX)
BUILD_EXIT=0

xcodebuild "${BUILD_ARGS[@]}" > "$BUILD_LOG" 2>&1 &
BUILD_PID=$!

# Show a progress counter while waiting
SECONDS_WAITED=0
while kill -0 "$BUILD_PID" 2>/dev/null; do
    if [ "$SECONDS_WAITED" -ge "$BUILD_TIMEOUT" ]; then
        echo ""
        error "Build timed out after ${BUILD_TIMEOUT}s — xcodebuild appears stuck."
        error "Killing build process tree..."
        # Kill the entire process group
        kill -9 -"$BUILD_PID" 2>/dev/null || kill -9 "$BUILD_PID" 2>/dev/null || true
        pkill -9 -P "$BUILD_PID" 2>/dev/null || true
        pkill -9 -f SWBBuildService 2>/dev/null || true
        wait "$BUILD_PID" 2>/dev/null || true
        echo ""
        error "Last build output:"
        tail -15 "$BUILD_LOG" >&2
        echo ""
        error "The Xcode build service (SWBBuildService) deadlocked."
        error "This is a known Xcode 26 beta bug. Just re-run this script."
        rm -f "$BUILD_LOG"
        exit 75
    fi
    # Print progress
    printf "\r  ${DIM}Building... (%ds)${RESET}  " "$SECONDS_WAITED"
    sleep 2
    SECONDS_WAITED=$((SECONDS_WAITED + 2))
done
printf "\r%40s\r" ""  # clear progress line

wait "$BUILD_PID" || BUILD_EXIT=$?

# Show build output on failure, or if verbose
if [ "$BUILD_EXIT" -ne 0 ]; then
    echo ""
    if $VERBOSE; then
        cat "$BUILD_LOG"
    else
        # Show just the errors
        grep -A2 'error:' "$BUILD_LOG" | head -40
    fi
    echo ""
    error "Build failed (exit code $BUILD_EXIT)."
    if ! $VERBOSE; then
        error "Re-run with -v to see full build output."
    fi
    rm -f "$BUILD_LOG"
    exit "$BUILD_EXIT"
elif $VERBOSE; then
    cat "$BUILD_LOG"
fi

rm -f "$BUILD_LOG"
success "Build succeeded. (${SECONDS_WAITED}s)"
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
