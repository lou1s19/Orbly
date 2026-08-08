#!/bin/bash
# Baut ein Distribution-DMG (App + Applications-Verknüpfung) aus der zuletzt
# gebauten App. Mit Developer-ID-Identität wird das DMG signiert und — falls ein
# notarytool-Profil "Orbly" hinterlegt ist — notarisiert + gestapelt.
# Nutzung: bash scripts/make-dmg.sh            (DMG nach ~/Library/Caches/Orbly/releases)
#          bash scripts/make-dmg.sh <ordner>   (anderes Ausgabeverzeichnis)
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="$HOME/Library/Caches/Orbly/build"
APP="$BUILD_DIR/Orbly.app"
[ -d "$APP" ] || { echo "App fehlt — erst 'bash scripts/build-app.sh' laufen lassen."; exit 1; }

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
OUT_DIR="${1:-$HOME/Library/Caches/Orbly/releases}"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/Orbly-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg-stage"

echo "==> Packe Orbly-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Orbly" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

IDENTITY="${ORBLY_SIGN_IDENTITY:-}"
case "$IDENTITY" in
"Developer ID"*)
  echo "==> Signiere DMG ($IDENTITY)"
  # Über den Hash signieren, genau wie build-app.sh. Über den Namen bricht
  # codesign ab ("ambiguous"), sobald zwei Zertifikate gleich heißen.
  IDENTITY_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "\"$IDENTITY\"" | awk 'NR==1{print $2}' || true)"
  [ -n "$IDENTITY_HASH" ] || { echo "FEHLER: '$IDENTITY' nicht im Schlüsselbund." >&2; exit 1; }
  codesign --force --timestamp --sign "$IDENTITY_HASH" "$DMG"
  if NOTARY_CHECK="$(xcrun notarytool history --keychain-profile Orbly 2>&1)"; then
    echo "==> Notarisiere bei Apple (dauert meist 1–5 Minuten) …"
    xcrun notarytool submit "$DMG" --keychain-profile Orbly --wait
    xcrun stapler staple "$DMG"
    echo "==> Notarisiert & gestapelt — läuft ohne Gatekeeper-Warnung."
  else
    # Nicht pauschal „kein Profil" melden: Netzfehler, abgelaufenes App-Passwort
    # und fehlendes Profil sehen sonst identisch aus.
    echo "Hinweis: notarytool nicht nutzbar — DMG ist signiert, aber NICHT notarisiert"
    echo "(Gatekeeper warnt auf fremden Macs). Meldung von Apple:"
    echo "$NOTARY_CHECK" | tail -3
    echo "Profil einrichten mit:"
    echo "  xcrun notarytool store-credentials Orbly --apple-id <apple-id> --team-id H8XJ9NV6ZQ"
  fi
  ;;
*)
  echo "Hinweis: ohne Developer-ID-Identität bleibt das DMG unsigniert (nur für dich selbst nutzbar)."
  ;;
esac

echo "DMG: $DMG"
