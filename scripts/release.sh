#!/bin/bash
# Erstellt ein Release: Version setzen, bauen, Update-Zip signieren, appcast.xml erzeugen.
# Nutzung: bash scripts/release.sh 1.1.0
# Danach veröffentlichen: bash scripts/publish-release.sh 1.1.0 "<Was ist neu>" (siehe RELEASING.md).
# Zips + appcast liegen im ÖFFENTLICHEN Repo lou1s19/Orbly-releases (Code bleibt privat).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Nutzung: bash scripts/release.sh <version, z. B. 1.1.0>}"
# Downloads und Update-Feed liegen bei der Website (Vercel), nicht auf GitHub.
# Damit muss kein Repo öffentlich sein. Achtung: Diese Feed-Adresse steckt in
# jeder ausgelieferten App. Sie muss erreichbar BLEIBEN, auch nach einem Umzug
# auf useorbly.com - dann dort eine Weiterleitung einrichten.
SITE_BASE="https://orbly-website.vercel.app"
REPO_DL="$SITE_BASE/download/"
FEED_URL="$SITE_BASE/appcast.xml"

# Bricht der Lauf ab (fehlendes Zertifikat, Notarisierung schlägt fehl), bleibt
# die Info.plist sonst mit hochgezählter Build-Nummer im Arbeitsbaum liegen.
PLIST_BAK="$(mktemp)"
cp Resources/Info.plist "$PLIST_BAK"
trap '[ "$?" -eq 0 ] || { cp "$PLIST_BAK" Resources/Info.plist; echo "Abbruch - Info.plist zurückgesetzt."; }; rm -f "$PLIST_BAK"' EXIT

echo "==> Setze Version $VERSION in Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
BUILD_NUM="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
BUILD_NUM=$((BUILD_NUM + 1))
plutil -replace CFBundleVersion -string "$BUILD_NUM" Resources/Info.plist
echo "    Build-Nummer: $BUILD_NUM"

# Sparkle vergleicht NUR die Build-Nummer. Wurde der Versions-Bump nach einem
# früheren Release nicht committet, entsteht dieselbe Nummer zweimal - dann
# sieht kein Nutzer das Update und nichts schlägt Alarm.
# Dieser Fehler hat keinen Reparaturweg, deshalb NICHT stillschweigend
# überspringen, wenn der Feed nicht erreichbar ist. Ein 404 ist dagegen der
# normale Zustand vor dem allerersten Release: Es gibt noch keine appcast.
FEED_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$FEED_URL" || echo "000")"
if [ "$FEED_CODE" = "404" ]; then
  echo "    Noch kein veröffentlichter Feed (HTTP 404), also erstes Release. Prüfung entfällt."
elif FEED_XML="$(curl -fsSL "$FEED_URL" 2>&1)"; then
  LIVE_BUILD="$(printf '%s' "$FEED_XML" | tr '>' '>\n' \
    | sed -n 's/.*<sparkle:version[^>]*>\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1 || true)"
  if [ -n "$LIVE_BUILD" ] && [ "$BUILD_NUM" -le "$LIVE_BUILD" ]; then
    echo "FEHLER: Build-Nummer $BUILD_NUM ist nicht höher als die veröffentlichte ($LIVE_BUILD)." >&2
    echo "        Der letzte Versions-Bump wurde nicht committet. In Resources/Info.plist" >&2
    echo "        CFBundleVersion auf mindestens $((LIVE_BUILD + 1)) setzen und committen." >&2
    exit 1
  fi
  echo "    Veröffentlichte Build-Nummer im Feed: ${LIVE_BUILD:-noch keine}"
elif [ "${ORBLY_SKIP_BUILD_CHECK:-0}" = "1" ]; then
  echo "    WARNUNG: Feed nicht erreichbar, Build-Nummern-Prüfung übersprungen (ORBLY_SKIP_BUILD_CHECK=1)."
else
  echo "FEHLER: Der Update-Feed ist nicht erreichbar, die Build-Nummer kann nicht geprüft werden." >&2
  echo "        Antwort: $(printf '%s' "$FEED_XML" | tail -1)" >&2
  echo "        Eine doppelte Build-Nummer würde bedeuten, dass niemand das Update sieht," >&2
  echo "        und das ist nachträglich nicht reparierbar. Entweder online gehen oder" >&2
  echo "        bewusst übergehen mit: ORBLY_SKIP_BUILD_CHECK=1 bash scripts/release.sh $VERSION" >&2
  exit 1
fi

echo "==> Baue App"
# NICHT installieren: Ein Release signiert mit der Developer ID. Würde die
# installierte App damit überschrieben, wechselt ihre Identität und macOS
# verwirft die Bedienungshilfen-Berechtigung (Stolperfalle 1). Die Alltags-App
# bleibt beim Dev-Zertifikat, das Release-Artefakt liegt in ~/Library/Caches.
ORBLY_NO_INSTALL=1 bash scripts/build-app.sh

RELEASE_DIR="$HOME/Library/Caches/Orbly/releases"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
APP_PATH="$HOME/Library/Caches/Orbly/build/Orbly.app"
ZIP="$RELEASE_DIR/Orbly-$VERSION.zip"

# WICHTIG: Erst notarisieren und stapeln, DANN das Update-Zip packen.
# Das Zip ist, was jede bestehende Installation per Sparkle herunterlädt und
# installiert. Vorher wurde nur das DMG notarisiert - das Zip enthielt also eine
# App ohne Notarisierungs-Ticket.
if [[ "${ORBLY_SIGN_IDENTITY:-}" == "Developer ID"* ]]; then
  if NOTARY_CHECK="$(xcrun notarytool history --keychain-profile Orbly 2>&1)"; then
    echo "==> Notarisiere App bei Apple (dauert meist 1-5 Minuten) …"
    UPLOAD_ZIP="$RELEASE_DIR/notarize-upload.zip"
    ditto -c -k --keepParent "$APP_PATH" "$UPLOAD_ZIP"
    xcrun notarytool submit "$UPLOAD_ZIP" --keychain-profile Orbly --wait
    rm -f "$UPLOAD_ZIP"
    xcrun stapler staple "$APP_PATH"
    echo "==> App notarisiert & gestapelt"
  else
    echo "FEHLER: notarytool-Profil 'Orbly' nicht nutzbar. Meldung von Apple:" >&2
    echo "$NOTARY_CHECK" | tail -3 >&2
    echo "        Einrichten mit: xcrun notarytool store-credentials Orbly --apple-id <apple-id> --team-id H8XJ9NV6ZQ" >&2
    exit 1
  fi
else
  echo "Hinweis: ohne ORBLY_SIGN_IDENTITY entsteht ein Test-Release nur für diesen Mac"
  echo "         (nicht notarisiert - publish-release.sh wird es ablehnen)."
fi

echo "==> Packe Update-Zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

echo "==> Signiere & erzeuge appcast.xml (EdDSA-Schlüssel aus dem Schlüsselbund)"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast "$RELEASE_DIR" \
  --download-url-prefix "$REPO_DL" \
  --maximum-versions 1

echo "==> Baue DMG (für Erst-Download / Website)"
bash scripts/make-dmg.sh "$RELEASE_DIR"

echo ""
echo "Fertig gebaut & signiert. Nächste Schritte (Details in RELEASING.md):"
echo "  1. bash scripts/publish-release.sh $VERSION '<Was ist neu>'"
echo "  2. git add -A && git commit -m 'release: v$VERSION' && git tag v$VERSION && git push --tags origin main"
