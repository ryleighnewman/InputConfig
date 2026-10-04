#!/bin/zsh
# Build the Homebrew distribution of InputConfig: a Developer ID signed, notarized .app,
# zipped for the tap's cask. Same recipe as YapToText's Scripts/release-homebrew.sh.
#
# Usage: scripts/release-homebrew.sh <git tag>      e.g. scripts/release-homebrew.sh 1.5-29
#
# Builds from the TAG (git archive), never the working tree, so unreleased branch work
# cannot leak into a public download.
#
# Differences from the App Store build:
#   1. Developer ID Application + hardened runtime + notarization, because anything
#      downloaded outside the App Store is blocked by Gatekeeper without it.
#   2. The helper (SteamControllerHelper) is built
#      universal (the Xcode project's Build Helpers phase does the same) and signed one by one with
#      their OWN entitlements (app-sandbox + inherit, nothing else). The app is signed
#      afterwards WITHOUT --deep, because --deep would overwrite the helpers' signatures
#      with the app's entitlements.
#   3. The tip jar shows its empty state: StoreKit has no products outside the App Store.
#
# Hosting: the zip is a release asset on the TAP repo (ryleighnewman/homebrew-inputconfig),
# not on ryleighnewman/InputConfig, so the main repo page is untouched. To host it on the
# main repo too, attach the same zip to that repo's release and change the cask url.
set -eu

TAG="${1:?usage: release-homebrew.sh <tag, e.g. 1.5-29>}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"          # the repo this script lives in
TAP="$(cd "$PROJ/.." && pwd)/homebrew-inputconfig"  # the tap repo, checked out beside it
WORK="$HOME/Library/Caches/InputConfigDD-Homebrew"   # outside iCloud: signed builds fail there
SRC="$WORK/src"
DD="$WORK/dd"
STAGE="$WORK/stage"
LOG="$WORK/homebrew.log"
mkdir -p "$WORK"; : > "$LOG"

DEVID=$(security find-identity -v -p codesigning | /usr/bin/grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
[ -n "$DEVID" ] || { echo "FATAL: no Developer ID Application certificate" | tee -a "$LOG"; exit 1; }
echo "signing identity: $DEVID" >> "$LOG"

# 0. Clean source from the tag.
rm -rf "$SRC" "$DD" "$STAGE"; mkdir -p "$SRC" "$STAGE"
git -C "$PROJ" archive "$TAG" | tar -x -C "$SRC"
VERSION=$(/usr/bin/grep -m1 "MARKETING_VERSION" "$SRC/InputConfig.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//')
BUILD=$(/usr/bin/grep -m1 "CURRENT_PROJECT_VERSION" "$SRC/InputConfig.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//')
ZIP="$WORK/InputConfig-${VERSION}.zip"
echo "building $VERSION ($BUILD) from tag $TAG" | tee -a "$LOG"

# 1. The helper first: the Xcode project copies SteamControllerHelper
#    from its folder into Contents/MacOS, so they must exist
#    before xcodebuild. Built universal; the project's Build Helpers phase would
#    build them too, this just makes the step explicit in the log.
for H in SteamControllerHelper; do
  for A in arm64 x86_64; do
    swiftc -O -target "$A-apple-macos14.0" -framework Foundation -framework IOKit \
      "$SRC/$H/main.swift" -o "$WORK/$H-$A" >> "$LOG" 2>&1
  done
  lipo -create "$WORK/$H-arm64" "$WORK/$H-x86_64" -output "$SRC/$H/$H"
done

# 2. Release build. Watchdog for the Xcode 26 wedge: the `clang -v -E -dM` probe can block
#    forever; a healthy one exits in under a second, so kill any alive past 30 s.
( while true; do
    for pid in $(pgrep -x clang); do
      cmd=$(ps -o command= -p $pid 2>/dev/null)
      et=$(ps -o etime= -p $pid 2>/dev/null | tr -d ' ')
      case "$cmd" in *"-v -E -dM"*) [[ "$et" == *:* ]] && { m=${et%%:*}; s=${et##*:}; [ $((10#$m*60+10#$s)) -gt 30 ] && kill $pid && echo "watchdog killed clang $pid" >> "$LOG"; } ;; esac
    done; sleep 5; done ) &
WD=$!
xcodebuild -project "$SRC/InputConfig.xcodeproj" -scheme InputConfig \
  -configuration Release -derivedDataPath "$DD" \
  -destination 'generic/platform=macOS' -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY="$DEVID" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= \
  DEVELOPMENT_TEAM=65JK8K8VGM OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  COMPILATION_CACHE_ENABLE_CACHING=NO build >> "$LOG" 2>&1 || true
kill $WD 2>/dev/null || true
/usr/bin/grep -q "BUILD SUCCEEDED" "$LOG" || { echo "FATAL: xcodebuild failed (see $LOG)" | tee -a "$LOG"; exit 1; }

BUILT="$DD/Build/Products/Release/InputConfig.app"
[ -d "$BUILT" ] || { echo "FATAL: build produced no app (see $LOG)" | tee -a "$LOG"; exit 1; }
ditto "$BUILT" "$STAGE/InputConfig.app"
APP="$STAGE/InputConfig.app"
MACOS="$APP/Contents/MacOS"
for H in SteamControllerHelper; do cp "$SRC/$H/$H" "$MACOS/$H"; done

xattr -cr "$APP"
for H in SteamControllerHelper; do
  codesign --force --timestamp --options=runtime \
    --entitlements "$SRC/$H/$H.entitlements" --sign "$DEVID" "$MACOS/$H" >> "$LOG" 2>&1
done

# 3b. The app itself, with the repo entitlements (the xcodebuild product also carries
#    get-task-allow in some configurations, which notarization rejects).
codesign --force --timestamp --options=runtime \
  --entitlements "$SRC/InputConfig/InputConfig.entitlements" --sign "$DEVID" "$APP" >> "$LOG" 2>&1
codesign --verify --deep --strict --verbose=2 "$APP" >> "$LOG" 2>&1

# HARD GATES: an app that cannot reach the controller is worse than no release.
# The app carries the device entitlements. Each helper carries exactly app-sandbox +
# inherit: it runs inside the app's sandbox, device access included. A helper with its
# own device entitlements and no inherit tries to start a sandbox of its own, has no
# bundle ID for a container, and dies with SIGTRAP before main (every build from
# June 2026 through 1.5 shipped that way).
for B in "$MACOS/InputConfig" "$MACOS/SteamControllerHelper"; do
  ENTS=$(codesign -d --entitlements - "$B" 2>/dev/null)
  if [ "$B" = "$MACOS/InputConfig" ]; then
    NEED="com.apple.security.app-sandbox com.apple.security.device.usb com.apple.security.device.bluetooth"
  else
    NEED="com.apple.security.app-sandbox com.apple.security.inherit"
    echo "$ENTS" | /usr/bin/grep -q -E "device\.usb|device\.bluetooth" \
      && { echo "FATAL: $B carries its own device entitlements; helpers must be sandbox + inherit only" | tee -a "$LOG"; exit 1; }
  fi
  for K in ${=NEED}; do
    echo "$ENTS" | /usr/bin/grep -q "$K" || { echo "FATAL: $B lacks $K" | tee -a "$LOG"; exit 1; }
  done
  echo "$ENTS" | /usr/bin/grep -q "get-task-allow" && { echo "FATAL: $B carries get-task-allow" | tee -a "$LOG"; exit 1; }
  [ "$(lipo -archs "$B")" = "x86_64 arm64" ] || [ "$(lipo -archs "$B")" = "arm64 x86_64" ] \
    || { echo "FATAL: $B is not universal ($(lipo -archs "$B"))" | tee -a "$LOG"; exit 1; }
done
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] \
  || { echo "FATAL: bundle version mismatch" | tee -a "$LOG"; exit 1; }

# 4. Notarize, staple, re-zip with the staple.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "submitting for notarization..." | tee -a "$LOG"
# This run's result only: the log is appended to, so a grep of the whole log
# could find an earlier run's "Accepted" after a failed submit.
NOTARY_OUT="$WORK/notarytool-$BUILD.txt"
xcrun notarytool submit "$ZIP" --keychain-profile "YapToTextNotary" --wait > "$NOTARY_OUT" 2>&1 \
  || { cat "$NOTARY_OUT" >> "$LOG"; echo "FATAL: notarytool failed (see $LOG)" | tee -a "$LOG"; exit 1; }
cat "$NOTARY_OUT" >> "$LOG"
/usr/bin/grep -q "status: Accepted" "$NOTARY_OUT" || { echo "FATAL: notarization not accepted (see $LOG)" | tee -a "$LOG"; exit 1; }
xcrun stapler staple "$APP" >> "$LOG" 2>&1
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 5. Gatekeeper check.
spctl --assess --type execute --verbose=4 "$APP" >> "$LOG" 2>&1 \
  || { echo "FATAL: Gatekeeper would reject this build" | tee -a "$LOG"; exit 1; }

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
if [ -f "$TAP/Casks/inputconfig.rb" ]; then
  /usr/bin/sed -i '' "s|^  version .*|  version \"${VERSION}\"|" "$TAP/Casks/inputconfig.rb"
  /usr/bin/sed -i '' "s|^  sha256 .*|  sha256 \"${SHA}\"|" "$TAP/Casks/inputconfig.rb"
  /usr/bin/sed -i '' "s|releases/download/v#{version}-[0-9]*|releases/download/v#{version}-${BUILD}|" "$TAP/Casks/inputconfig.rb"
fi
echo "DONE  $ZIP" | tee -a "$LOG"
echo "  version $VERSION ($BUILD)   sha256 $SHA" | tee -a "$LOG"
