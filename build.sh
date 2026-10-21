#!/bin/bash
# Builds VaultWatch.app (menu bar app, no Dock icon) from the Swift package.
#
# Usage:
#   ./build.sh              build to build/VaultWatch.app
#   ./build.sh --install    build, then install to /Applications
#
# Optional environment (used by CI):
#   UNIVERSAL=1             build for Apple silicon + Intel
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#                           sign with hardened runtime + timestamp (default: ad-hoc "-")
#   VERSION=0.3.0           sets CFBundleShortVersionString
#   BUILD_NUMBER=42         sets CFBundleVersion
#
# The FIRST build takes 1-3 minutes. Don't interrupt it at "Write swift-version".
set -euo pipefail
cd "$(dirname "$0")"

# Use Apple's toolchain (Xcode / Command Line Tools) via xcrun. A swiftly/open-source
# toolchain earlier on PATH can fail to import SwiftUI against the macOS SDK.
if xcrun --find swift >/dev/null 2>&1; then
    SWIFT=(xcrun swift)
else
    SWIFT=(swift)
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "Using: $("${SWIFT[@]}" --version 2>&1 | head -1)"
echo "Building (first build takes 1-3 minutes)..."

# ${ARCH_FLAGS[@]+...} keeps bash 3.2 (macOS default) happy with an empty array under set -u.
"${SWIFT[@]}" build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$("${SWIFT[@]}" build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/VaultWatch"

APP="build/VaultWatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VaultWatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

PLIST="$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    # Ad-hoc: fine for building on your own Mac.
    codesign --force --sign - "$APP"
else
    # Developer ID: hardened runtime + secure timestamp, required for notarization.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/VaultWatch"))"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'tell application "VaultWatch" to quit' >/dev/null 2>&1 || true

    # One-time migration from the pre-rename build: quit it and move it to the Trash.
    if [[ -d /Applications/ObSyncBar.app ]]; then
        echo "Replacing the old ObSyncBar.app (moved to Trash)..."
        osascript -e 'tell application "ObSyncBar" to quit' >/dev/null 2>&1 || true
        sleep 2
        osascript -e 'tell application "Finder" to delete POSIX file "/Applications/ObSyncBar.app"' >/dev/null 2>&1 \
            || echo "  Could not move ObSyncBar.app to Trash; delete it from /Applications yourself."
    fi

    sleep 1
    rm -rf /Applications/VaultWatch.app
    cp -R "$APP" /Applications/VaultWatch.app
    touch /Applications/VaultWatch.app   # refresh Finder's icon cache
    echo "Installed to /Applications/VaultWatch.app"
fi
