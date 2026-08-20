#!/bin/bash
# Builds a distribution DMG from the app that was built last: the app on the
# left, an Applications shortcut on the right, and a background that says to
# drag one onto the other. With a Developer ID identity the DMG is signed and,
# if a notarytool profile named "Orbly" exists, notarized and stapled.
# Usage: bash scripts/make-dmg.sh            (DMG into ~/Library/Caches/Orbly/releases)
#        bash scripts/make-dmg.sh <folder>   (different output directory)
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

BUILD_DIR="$HOME/Library/Caches/Orbly/build"
APP="$BUILD_DIR/Orbly.app"
[ -d "$APP" ] || { echo "App missing, run 'bash scripts/build-app.sh' first."; exit 1; }

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
OUT_DIR="${1:-$HOME/Library/Caches/Orbly/releases}"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/Orbly-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg-stage"
RW_DMG="$BUILD_DIR/Orbly-rw.dmg"
VOLUME="Orbly"

# Window and icon layout. The background image is drawn for exactly this size,
# so the three numbers belong together: change one and the arrow points nowhere.
WIN_WIDTH=660
WIN_HEIGHT=379
APP_X=180
APP_Y=140
FOLDER_X=480
FOLDER_Y=140
ICON_SIZE=128

echo "==> Staging Orbly-$VERSION.dmg"
rm -rf "$STAGE" "$DMG" "$RW_DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ -f "Resources/dmg-background.png" ]; then
  mkdir -p "$STAGE/.background"
  cp "Resources/dmg-background.png" "$STAGE/.background/background.png"
fi

# A read-write image first, because the window layout is stored in the volume
# itself and can only be written while it is mounted.
SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 20000 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
  -format UDRW -size "${SIZE_KB}k" "$RW_DMG" >/dev/null

# Mount it and find out what the volume is really called. If a volume named
# "Orbly" is already mounted, for example the released DMG, macOS names this one
# "Orbly 1", and scripting "disk Orbly" would then lay out somebody else's
# mounted image instead of this one.
ATTACH_OUT="$(hdiutil attach "$RW_DMG" -nobrowse -noautoopen)"
MOUNT_DIR="$(printf '%s' "$ATTACH_OUT" | grep -o '/Volumes/.*' | tail -1)"
VOLUME_NAME="$(basename "$MOUNT_DIR")"
[ -d "$MOUNT_DIR" ] || { echo "ERROR: could not mount $RW_DMG" >&2; exit 1; }
cleanup() { hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true; }
trap cleanup EXIT

# Finder writes the layout into the volume's .DS_Store. If this fails, for
# example because Terminal may not control Finder, the DMG is still usable, it
# just looks like a plain folder. That is a worse installer, not a broken one.
if [ -f "$STAGE/.background/background.png" ]; then
  echo "==> Laying out the installer window (volume: $VOLUME_NAME)"
  osascript >/dev/null 2>&1 <<EOF || echo "    Skipped: Finder could not be scripted (System Settings > Privacy & Security > Automation)."
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_WIDTH)), $((120 + WIN_HEIGHT + 22))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set background picture of opts to file ".background:background.png"
    set position of item "Orbly.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$FOLDER_X, $FOLDER_Y}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
  sync
fi

hdiutil detach "$MOUNT_DIR" -quiet
trap - EXIT

echo "==> Compressing"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGE"

IDENTITY="${ORBLY_SIGN_IDENTITY:-}"
case "$IDENTITY" in
"Developer ID"*)
  echo "==> Signing the DMG ($IDENTITY)"
  # Sign by hash, exactly like build-app.sh does. By name codesign aborts with
  # "ambiguous" as soon as two certificates carry the same name.
  IDENTITY_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "\"$IDENTITY\"" | awk 'NR==1{print $2}' || true)"
  [ -n "$IDENTITY_HASH" ] || { echo "ERROR: '$IDENTITY' is not in the keychain." >&2; exit 1; }
  codesign --force --timestamp --sign "$IDENTITY_HASH" "$DMG"
  if NOTARY_CHECK="$(xcrun notarytool history --keychain-profile Orbly 2>&1)"; then
    echo "==> Notarizing with Apple (usually 1-5 minutes) …"
    xcrun notarytool submit "$DMG" --keychain-profile Orbly --wait
    xcrun stapler staple "$DMG"
    echo "==> Notarized and stapled, runs without a Gatekeeper warning."
  else
    # Do not report a blanket "no profile": a network error, an expired app
    # password and a missing profile would otherwise look identical.
    echo "Note: notarytool not usable, the DMG is signed but NOT notarized"
    echo "(Gatekeeper warns on other people's Macs). Apple says:"
    echo "$NOTARY_CHECK" | tail -3
    echo "Set up a profile with:"
    echo "  xcrun notarytool store-credentials Orbly --apple-id <apple-id> --team-id \"\$ORBLY_TEAM_ID\""
  fi
  ;;
*)
  echo "Note: without a Developer ID identity the DMG stays unsigned (usable on this Mac only)."
  ;;
esac

echo "DMG: $DMG"
