#!/bin/bash
# Build JoystickConfig and include LightHelper in the app bundle.
# Usage: ./build_and_archive.sh [debug|release|archive]

set -e
cd "$(dirname "$0")"

MODE="${1:-debug}"
HELPER_SRC="LightHelper/main.swift"
HELPER_ENTITLEMENTS="LightHelper/LightHelper.entitlements"
TOUCHPAD_HELPER_SRC="TouchpadHelper/main.swift"
TOUCHPAD_HELPER_ENTITLEMENTS="TouchpadHelper/TouchpadHelper.entitlements"
STEAM_HELPER_SRC="SteamControllerHelper/main.swift"
STEAM_HELPER_ENTITLEMENTS="SteamControllerHelper/SteamControllerHelper.entitlements"

# (Previously killed xcodebuild/XCBBuildService here on every run, which
# discarded incremental-build state and forced a full rebuild. Removed -
# only kill them if you observe a CreateBuildOperation hang.)

# Only rebuild a helper if its source is newer than the binary.
build_helper_if_needed() {
    local src="$1"
    local out="$2"
    local name="$3"
    if [ ! -f "$out" ] || [ "$src" -nt "$out" ]; then
        echo "=== Building $name ==="
        swiftc -O -framework Foundation -framework IOKit "$src" -o "$out"
    fi
}
build_helper_if_needed "$HELPER_SRC" "LightHelper/LightHelper" "LightHelper"
build_helper_if_needed "$TOUCHPAD_HELPER_SRC" "TouchpadHelper/TouchpadHelper" "TouchpadHelper"
build_helper_if_needed "$STEAM_HELPER_SRC" "SteamControllerHelper/SteamControllerHelper" "SteamControllerHelper"

# Get the team ID from the main app's signing
TEAM_ID=$(security find-identity -v -p codesigning | grep "Apple Distribution\|Developer ID\|3rd Party Mac Developer" | head -1 | grep -o '"[^"]*"' | tr -d '"' | head -1)
if [ -z "$TEAM_ID" ]; then
    TEAM_ID=$(security find-identity -v -p codesigning | head -1 | grep -o '"[^"]*"' | tr -d '"')
fi
echo "Signing identity: $TEAM_ID"

if [ "$MODE" = "archive" ]; then
    echo "=== Archiving JoystickConfig ==="
    xcodebuild -scheme JoystickConfig \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -skipPackagePluginValidation \
        archive \
        -archivePath build/JoystickConfig.xcarchive

    # Copy helpers into the archive and sign them
    MACOS_DIR="build/JoystickConfig.xcarchive/Products/Applications/JoystickConfig.app/Contents/MacOS"
    cp LightHelper/LightHelper "$MACOS_DIR/"
    cp TouchpadHelper/TouchpadHelper "$MACOS_DIR/"
    cp SteamControllerHelper/SteamControllerHelper "$MACOS_DIR/"

    echo "=== Signing LightHelper ==="
    codesign --force --sign "$TEAM_ID" \
        --entitlements "$HELPER_ENTITLEMENTS" \
        --options runtime \
        "$MACOS_DIR/LightHelper"

    echo "=== Signing TouchpadHelper ==="
    codesign --force --sign "$TEAM_ID" \
        --entitlements "$TOUCHPAD_HELPER_ENTITLEMENTS" \
        --options runtime \
        "$MACOS_DIR/TouchpadHelper"

    echo "=== Signing SteamControllerHelper ==="
    codesign --force --sign "$TEAM_ID" \
        --entitlements "$STEAM_HELPER_ENTITLEMENTS" \
        --options runtime \
        "$MACOS_DIR/SteamControllerHelper"

    echo "=== Verifying signatures ==="
    codesign -dvv "$MACOS_DIR/LightHelper" 2>&1 | grep -E "Identifier|Authority|Entitlements"
    codesign -dvv "$MACOS_DIR/TouchpadHelper" 2>&1 | grep -E "Identifier|Authority|Entitlements"
    codesign -dvv "$MACOS_DIR/SteamControllerHelper" 2>&1 | grep -E "Identifier|Authority|Entitlements"

    echo "=== Archive ready at build/JoystickConfig.xcarchive ==="
    echo "Open in Xcode: open build/JoystickConfig.xcarchive"
else
    CONFIG="Debug"
    [ "$MODE" = "release" ] && CONFIG="Release"

    echo "=== Building JoystickConfig ($CONFIG) ==="
    # -jobs 1 was historically required because the Xcode *GUI* hung at
    # CreateBuildOperation on this machine. The CLI does not have the same
    # bug, so we let xcodebuild use all cores for ~3-4× faster builds.
    xcodebuild -scheme JoystickConfig \
        -configuration "$CONFIG" \
        -destination 'platform=macOS,arch=arm64' \
        -skipPackagePluginValidation \
        build

    # Find and copy helpers into the built app
    APP=$(find ~/Library/Developer/Xcode/DerivedData/JoystickConfig-*/Build/Products/$CONFIG -name "JoystickConfig.app" -maxdepth 1 2>/dev/null | head -1)
    if [ -n "$APP" ]; then
        cp LightHelper/LightHelper "$APP/Contents/MacOS/"
        cp TouchpadHelper/TouchpadHelper "$APP/Contents/MacOS/"
        cp SteamControllerHelper/SteamControllerHelper "$APP/Contents/MacOS/"
        echo "=== Build complete: $APP ==="
        echo "Run: open \"$APP\""
    fi
fi
