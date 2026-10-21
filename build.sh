#!/bin/bash
# Builds VaultWatch.app (menu bar app, no Dock icon) from the Swift package.
# Usage: ./build.sh [--install]
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
echo "Using: $("${SWIFT[@]}" --version 2>&1 | head -1)"
echo "Building (first build takes 1-3 minutes)..."

"${SWIFT[@]}" build -c release
BIN="$("${SWIFT[@]}" build -c release --show-bin-path)/VaultWatch"

APP="build/VaultWatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VaultWatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS lets the login item and notifications work locally.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
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
    # Refresh Finder/Dock icon cache for the new bundle.
    touch /Applications/VaultWatch.app
    echo "Installed to /Applications/VaultWatch.app"
fi
