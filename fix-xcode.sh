#!/bin/bash
#
# Fixes the "get clang version info" hang in Xcode.
# Clears the Clang module cache and this project's DerivedData.
# Safe to run anytime — just adds ~30s to the next build.
#

echo "Killing Xcode and build services..."
pkill -9 -f 'Xcode' 2>/dev/null
pkill -9 -f 'xcodebuild' 2>/dev/null
pkill -9 -f 'SWBBuildService' 2>/dev/null
pkill -9 -f 'XCBBuildService' 2>/dev/null
sleep 1

echo "Clearing Clang module cache..."
rm -rf "$(getconf DARWIN_USER_CACHE_DIR)org.llvm.clang"

echo "Clearing PrintParty DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/PrintParty-*
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$SCRIPT_DIR/.build-derived-data"

echo "Done. Relaunch Xcode."
