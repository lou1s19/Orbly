#!/bin/bash
# Builds a distribution DMG (app + Applications shortcut) from the app that was
# built last. With a Developer ID identity the DMG is signed and, if a notarytool
# profile named "Orbly" exists, notarized and stapled.
# Usage: bash scripts/make-dmg.sh            (DMG into ~/Library/Caches/Orbly/releases)
#        bash scripts/make-dmg.sh <folder>   (different output directory)
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="$HOME/Library/Caches/Orbly/build"
APP="$BUILD_DIR/Orbly.app"
[ -d "$APP" ] || { echo "App missing, run 'bash scripts/build-app.sh' first."; exit 1; }

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
OUT_DIR="${1:-$HOME/Library/Caches/Orbly/releases}"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/Orbly-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg-stage"

echo "==> Packing Orbly-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Orbly" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
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
