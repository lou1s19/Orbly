#!/bin/bash
# Veröffentlicht ein mit release.sh gebautes Release über die WEBSITE (Vercel):
#   1. Update-Zip, DMG und appcast.xml in das Website-Repo legen
#   2. committen und pushen -> Vercel deployt -> Download und Update sind live
#
# Warum über die Website und nicht über GitHub-Releases: Download-Knopf und
# Update-Feed kommen so von derselben Adresse, und die Dateinamen bleiben stabil
# (public/download/Orbly.dmg). Ein GitHub-Release ist zusätzlich möglich, ist
# aber nicht der Kanal, den Sparkle abfragt.
#
# Nutzung: bash scripts/publish-release.sh 1.1.0 "Was ist neu ..."
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Nutzung: bash scripts/publish-release.sh <version> [release-notes]}"
NOTES="${2:-Orbly $VERSION}"
RELEASE_DIR="$HOME/Library/Caches/Orbly/releases"
SITE_REPO="${ORBLY_SITE_REPO:-$HOME/Desktop/orbly-website}"
SITE_BASE="${ORBLY_SITE_BASE:-https://orbly-website.vercel.app}"
ZIP="$RELEASE_DIR/Orbly-$VERSION.zip"
DMG="$RELEASE_DIR/Orbly-$VERSION.dmg"
APPCAST="$RELEASE_DIR/appcast.xml"

[ -f "$ZIP" ] || { echo "Fehlt: $ZIP - erst 'bash scripts/release.sh $VERSION' laufen lassen."; exit 1; }
[ -f "$APPCAST" ] || { echo "Fehlt: $APPCAST - erst 'bash scripts/release.sh $VERSION' laufen lassen."; exit 1; }
[ -d "$SITE_REPO/.git" ] || { echo "Website-Repo nicht gefunden: $SITE_REPO"; exit 1; }

# ---------------------------------------------------------------------------
# Sicherheitsgate für das Update-Zip.
#
# Das ist der Weg, über den bestehende Installationen aktualisiert werden. Passt
# die App darin Gatekeeper nicht oder wechselt die Signier-Identität, lehnt
# Sparkle das Update dauerhaft ab, und es gibt keinen zweiten Kanal, das zu
# reparieren. Deshalb hart prüfen, nicht nur das DMG.
# ---------------------------------------------------------------------------
ZIP_CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$ZIP_CHECK_DIR"' EXIT
ditto -x -k "$ZIP" "$ZIP_CHECK_DIR"
ZIP_APP="$ZIP_CHECK_DIR/Orbly.app"
[ -d "$ZIP_APP" ] || { echo "ABBRUCH: $ZIP enthält keine Orbly.app."; exit 1; }

ZIP_OK=1
xcrun stapler validate "$ZIP_APP" >/dev/null 2>&1 || ZIP_OK=0
spctl -a -t exec -vv "$ZIP_APP" >/dev/null 2>&1 || ZIP_OK=0
# KEIN `| grep -q` hier: grep schließt die Pipe nach dem ersten Treffer, codesign
# bekommt SIGPIPE (Exit 141), und `pipefail` macht daraus einen Fehlschlag. Das
# Gate hätte dann ein völlig korrektes Release abgelehnt (genau so passiert am
# 2026-08-03). Ausgabe erst einsammeln, dann prüfen.
CODESIGN_OUT="$(codesign -dv --verbose=4 "$ZIP_APP" 2>&1 || true)"
case "$CODESIGN_OUT" in
  *"Authority=Developer ID Application"*) ;;
  *) ZIP_OK=0 ;;
esac
# Universal: Eine arm64-only-App startet auf Intel-Macs gar nicht.
for F in "$ZIP_APP/Contents/MacOS/Orbly" \
         "$ZIP_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
         "$ZIP_APP/Contents/Helpers/whisper-server"; do
  [ -f "$F" ] || { echo "ABBRUCH: $F fehlt im Zip."; exit 1; }
  case "$(lipo -archs "$F")" in
    *x86_64*arm64*|*arm64*x86_64*) ;;
    *) echo "ABBRUCH: $(basename "$F") im Zip ist nicht universal."; exit 1 ;;
  esac
done

if [ "$ZIP_OK" != "1" ]; then
  if [ "${ORBLY_ALLOW_UNNOTARIZED:-0}" = "1" ]; then
    echo "WARNUNG: Update-Zip ist nicht notarisiert oder nicht mit Developer ID signiert."
    echo "         Wird wegen ORBLY_ALLOW_UNNOTARIZED=1 trotzdem veröffentlicht."
  else
    echo "ABBRUCH: Die App im Update-Zip ist nicht mit Developer ID signiert, notarisiert"
    echo "         und gestapelt. So würde Sparkle das Update bei allen Nutzern ablehnen"
    echo "         und der Fehler wäre nicht mehr reparierbar. Details:"
    printf '%s\n' "$CODESIGN_OUT" | grep -E "Authority|Identifier" || true
    spctl -a -t exec -vv "$ZIP_APP" 2>&1 | tail -2 || true
    echo "         Richtig bauen mit:"
    echo "         ORBLY_SIGN_IDENTITY=\"Developer ID Application: Louis Saks (H8XJ9NV6ZQ)\" bash scripts/release.sh $VERSION"
    exit 1
  fi
fi

if [ -f "$DMG" ]; then
  if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    if [ "${ORBLY_ALLOW_UNNOTARIZED:-0}" != "1" ]; then
      echo "ABBRUCH: $DMG ist nicht notarisiert/gestapelt - Gatekeeper würde es blocken."
      exit 1
    fi
    echo "WARNUNG: DMG nicht notarisiert, wird wegen ORBLY_ALLOW_UNNOTARIZED=1 trotzdem hochgeladen."
  fi
fi

# ---------------------------------------------------------------------------
# In die Website legen
# ---------------------------------------------------------------------------
DL_DIR="$SITE_REPO/public/download"
mkdir -p "$DL_DIR"

echo "==> Alte Versionen aus der Website entfernen (hält das Repo klein)"
# Nur die aktuelle Version muss liegen: Die appcast bewirbt ohnehin nur die
# neueste (--maximum-versions 1), und der Download-Knopf zeigt auf Orbly.dmg.
find "$DL_DIR" -maxdepth 1 -type f \( -name 'Orbly-*.zip' -o -name 'Orbly-*.dmg' \) -delete

echo "==> Dateien kopieren"
cp "$ZIP" "$DL_DIR/"
[ -f "$DMG" ] && cp "$DMG" "$DL_DIR/"
# Fester Name für den Download-Knopf der Website, damit dort pro Release nichts
# angefasst werden muss.
[ -f "$DMG" ] && cp "$DMG" "$DL_DIR/Orbly.dmg"
# Die appcast liegt im Wurzelverzeichnis: https://<site>/appcast.xml
cp "$APPCAST" "$SITE_REPO/public/appcast.xml"

echo "==> Prüfen, dass die appcast auf erreichbare Dateien zeigt"
# Ein Tippfehler im Pfad würde bedeuten, dass Sparkle ins Leere lädt.
ENCL="$(grep -o 'url="[^"]*"' "$SITE_REPO/public/appcast.xml" | head -1 | sed 's/url="//;s/"//')"
ENCL_FILE="$(basename "$ENCL")"
[ -f "$DL_DIR/$ENCL_FILE" ] || {
  echo "ABBRUCH: Die appcast verweist auf '$ENCL_FILE', diese Datei liegt aber nicht in public/download/."
  exit 1
}

echo "==> Website committen und pushen (Vercel deployt automatisch)"
cd "$SITE_REPO"
BRANCH="$(git branch --show-current)"
git add public/download public/appcast.xml
if git diff --staged --quiet; then
  echo "    Keine Änderungen, nichts zu pushen."
else
  git commit -q -m "release: Orbly $VERSION

$NOTES"
  git push origin "$BRANCH"
fi

echo ""
echo "Veröffentlicht über die Website."
echo "  Download:    $SITE_BASE/download/Orbly.dmg"
echo "  Update-Feed: $SITE_BASE/appcast.xml"
echo ""
echo "Vercel braucht ein bis zwei Minuten für das Deployment. Danach prüfen:"
echo "  curl -sI $SITE_BASE/appcast.xml | head -1"
echo ""
echo "Nicht vergessen: Im App-Repo den Versions-Bump committen und Tag v$VERSION setzen."
