#!/bin/bash
# Build InputConfig with its Steam Controller helper.
# Usage: ./build_and_archive.sh [debug|release|archive|install]

set -e
cd "$(dirname "$0")"

MODE="${1:-debug}"
STEAM_HELPER_SRC="SteamControllerHelper/main.swift"
STEAM_HELPER_ENTITLEMENTS="SteamControllerHelper/SteamControllerHelper.entitlements"

# Do not kill xcodebuild/XCBBuildService here. That discards incremental
# build state and forces a full rebuild. Only kill them if you hit a
# CreateBuildOperation hang.

# Only rebuild a helper if its source is newer than the binary, or the binary
# is not universal. Built for both Apple silicon and Intel: through 1.5 (29)
# the helpers were built for the machine doing the build only, so the App
# Store copy shipped them arm64 only and on an Intel Mac the Steam
# Controller helper could not start. The Xcode project's Build Helpers
# phase now does the same on every build.
build_helper_if_needed() {
    local src="$1"
    local out="$2"
    local name="$3"
    local archs
    archs=$(lipo -archs "$out" 2>/dev/null || true)
    case "$archs" in *arm64*) ;; *) archs="" ;; esac
    case "$archs" in *x86_64*) ;; *) archs="" ;; esac
    if [ ! -f "$out" ] || [ "$src" -nt "$out" ] || [ -z "$archs" ]; then
        echo "=== Building $name (universal) ==="
        swiftc -O -target arm64-apple-macos14.0 -framework Foundation -framework IOKit "$src" -o "$out.arm64"
        swiftc -O -target x86_64-apple-macos14.0 -framework Foundation -framework IOKit "$src" -o "$out.x86_64"
        lipo -create "$out.arm64" "$out.x86_64" -output "$out"
        rm -f "$out.arm64" "$out.x86_64"
    fi
}
build_helper_if_needed "$STEAM_HELPER_SRC" "SteamControllerHelper/SteamControllerHelper" "SteamControllerHelper"

# Signing is Xcode's: the project's Sign Helpers phase signs the helper with
# the identity the build uses, and nothing here re-signs after Xcode seals it.

if [ "$MODE" = "archive" ]; then
    echo "=== Archiving InputConfig ==="
    # Outside the iCloud-synced project, so no iCloud attributes reach the
    # archive, with Xcode 26's compilation cache off, and with the watchdog
    # for the clang probe that can block forever (both needed for 1.5).
    OUT="$HOME/Library/Caches/InputConfigArchive"
    ARCHIVE="$OUT/InputConfig.xcarchive"
    mkdir -p "$OUT"
    ( while true; do
        for pid in $(pgrep -x clang); do
          cmd=$(ps -o command= -p $pid 2>/dev/null)
          et=$(ps -o etime= -p $pid 2>/dev/null | tr -d ' ')
          case "$cmd" in *"-v -E -dM"*) [[ "$et" == *:* ]] && { m=${et%%:*}; s=${et##*:}; [ $((10#$m*60+10#$s)) -gt 30 ] && kill $pid; } ;; esac
        done; sleep 5; done ) &
    WATCHDOG=$!
    trap 'kill $WATCHDOG 2>/dev/null || true' EXIT
    xcodebuild -scheme InputConfig \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -skipPackagePluginValidation \
        -derivedDataPath "$OUT/DerivedData" \
        COMPILATION_CACHE_ENABLE_CACHING=NO \
        archive \
        -archivePath "$ARCHIVE"
    kill $WATCHDOG 2>/dev/null || true

    # The project's Copy Helpers and Sign Helpers phases put the signed
    # helpers in the app before Xcode seals it. Copying and re-signing them
    # here, after the seal, broke the app's signature, so this only checks.
    APP="$ARCHIVE/Products/Applications/InputConfig.app"
    MACOS_DIR="$APP/Contents/MacOS"

    echo "=== Verifying signatures ==="
    if codesign --verify --strict --deep "$APP" 2>&1; then
        echo "  app signature VALID"
    else
        echo "  ERROR: the app's signature does not verify"
        exit 1
    fi
    codesign -dvv "$MACOS_DIR/SteamControllerHelper" 2>&1 | /usr/bin/grep -E "Identifier|Authority"
    # The helper carries exactly app-sandbox + inherit: it runs inside the
    # app's sandbox. Its own device entitlements fail App Store validation
    # and made every helper die before main through 1.5.
    HELPER_ENTS=$(codesign -d --entitlements - --xml "$MACOS_DIR/SteamControllerHelper" 2>/dev/null)
    for KEY in com.apple.security.app-sandbox com.apple.security.inherit; do
        if ! echo "$HELPER_ENTS" | /usr/bin/grep -q "$KEY"; then
            echo "  ERROR: SteamControllerHelper lacks $KEY"
            exit 1
        fi
    done
    if echo "$HELPER_ENTS" | /usr/bin/grep -q -E "device\.usb|device\.bluetooth"; then
        echo "  ERROR: SteamControllerHelper carries its own device entitlements; it must be sandbox + inherit only"
        exit 1
    fi
    echo "  helper entitlements OK (app-sandbox + inherit)"

    echo "=== Archive ready at $ARCHIVE ==="
    echo "Open in Xcode: open \"$ARCHIVE\""
elif [ "$MODE" = "install" ]; then
    # Build a Release copy, bundle the signed helpers, and install it to
    # /Applications/InputConfig.app, a stable and properly-signed location.
    # macOS keys Accessibility / Input Monitoring grants to the app's code
    # signature (bundle id + Apple Development cert), which is identical across
    # rebuilds, so the user grants once and it sticks instead of re-prompting
    # for a fresh DerivedData build every time.
    echo "=== Building InputConfig (Release) for install ==="
    xcodebuild -scheme InputConfig \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -skipPackagePluginValidation \
        build

    SRC=$(find ~/Library/Developer/Xcode/DerivedData/InputConfig-*/Build/Products/Release -name "InputConfig.app" -maxdepth 1 2>/dev/null | head -1)
    if [ -z "$SRC" ]; then echo "Release build not found"; exit 1; fi
    DEST="/Applications/InputConfig.app"
    # Never replace the Mac App Store copy: it has a receipt, and deleting
    # it silently lost the purchased install.
    if [ -e "$DEST/Contents/_MASReceipt" ]; then
        echo "Refusing: $DEST is the Mac App Store copy. Move it aside first if you mean to replace it."
        exit 1
    fi
    echo "=== Installing $SRC -> $DEST ==="
    # A previous development copy goes to the Trash rather than being deleted.
    if [ -e "$DEST" ]; then
        mv "$DEST" "$HOME/.Trash/InputConfig-dev-$(date +%Y%m%d-%H%M%S).app"
    fi
    # As built: the Copy Helpers and Sign Helpers phases already signed the
    # helper inside it with the identity Xcode used. Re-signing here with
    # the first certificate in the keychain could change the signature, and
    # the Accessibility and Input Monitoring grants with it.
    ditto "$SRC" "$DEST"

    echo "=== Verifying ==="
    codesign --verify --strict "$DEST" 2>&1 && echo "  app signature VALID" || echo "  app signature check reported issues"
    codesign -dvv "$DEST/Contents/MacOS/SteamControllerHelper" 2>&1 | /usr/bin/grep -E "Identifier|flags|Authority=Apple"

    echo "=== Installed: $DEST ==="
    echo "Open: open \"$DEST\""
else
    CONFIG="Debug"
    [ "$MODE" = "release" ] && CONFIG="Release"

    echo "=== Building InputConfig ($CONFIG) ==="
    # Let xcodebuild use all cores. -jobs 1 is only needed for the Xcode GUI,
    # which can hang at CreateBuildOperation; the command-line build does not.
    xcodebuild -scheme InputConfig \
        -configuration "$CONFIG" \
        -destination 'generic/platform=macOS' \
        -skipPackagePluginValidation \
        build

    # The project's Copy Helpers and Sign Helpers phases already put the
    # signed helpers in the built app; re-signing them here after Xcode
    # sealed it broke the app's signature.
    APP=$(find ~/Library/Developer/Xcode/DerivedData/InputConfig-*/Build/Products/$CONFIG -name "InputConfig.app" -maxdepth 1 2>/dev/null | head -1)
    if [ -n "$APP" ]; then
        echo "=== Build complete: $APP ==="
        echo "Run: open \"$APP\""
    fi
fi
