#!/bin/bash
# Builds Orbly.app from the Swift package and installs it.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"
APP_NAME="Orbly"
# NICHT im Projektordner bauen: der Desktop ist iCloud-synchronisiert und der
# File-Provider stempelt dem Bundle laufend FinderInfo-xattrs auf, an denen
# codesign scheitert ("resource fork ... not allowed").
BUILD_DIR="$HOME/Library/Caches/Orbly/build"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/$APP_NAME.app"

# Universal bauen (Apple Silicon + Intel). Bei zwei Architekturen legt SwiftPM
# die Produkte nach .build/apple/Products/Release statt .build/release.
echo "==> swift build -c release (universal: arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
PRODUCTS=".build/apple/Products/Release"
[ -f "$PRODUCTS/$APP_NAME" ] || { echo "FEHLER: $PRODUCTS/$APP_NAME fehlt." >&2; exit 1; }

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# Sparkle-Framework (Auto-Updates) einbetten + Suchpfad setzen
mkdir -p "$APP/Contents/Frameworks"
cp -R "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Logo (Sidebar) + App-Icon aus Resources/logo.png, falls vorhanden
if [ -f "Resources/logo.png" ]; then
  cp "Resources/logo.png" "$APP/Contents/Resources/logo.png"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "Resources/logo.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "Resources/logo.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# Whisper-Engine mitliefern. Ohne sie bräuchte der Nutzer Homebrew, und damit
# wäre die App für alle unbenutzbar, die das nicht haben.
ENGINE="$PROJECT_DIR/vendor/whisper-server"
if [ ! -f "$ENGINE" ] && command -v cmake >/dev/null 2>&1; then
  echo "==> Whisper-Engine fehlt, wird gebaut (einmalig, dauert einige Minuten)"
  bash "$PROJECT_DIR/scripts/build-whisper-engine.sh"
fi
if [ -f "$ENGINE" ]; then
  mkdir -p "$APP/Contents/Helpers"
  cp "$ENGINE" "$APP/Contents/Helpers/whisper-server"
  chmod +x "$APP/Contents/Helpers/whisper-server"
elif [[ "${ORBLY_SIGN_IDENTITY:-}" == "Developer ID"* ]]; then
  # Für ein Release ist das ein harter Fehler: Ohne mitgelieferte Engine
  # bräuchte jeder Nutzer Homebrew, und die App wäre für die meisten unbenutzbar.
  echo "FEHLER: Die Whisper-Engine fehlt ($ENGINE)." >&2
  echo "        Ein Release ohne Engine ist für Nutzer ohne Homebrew unbenutzbar." >&2
  echo "        Erzeugen mit: brew install cmake && bash scripts/build-whisper-engine.sh" >&2
  exit 1
else
  # Lokaler Entwicklungs-Build: weiterbauen, die App nimmt dann das
  # Homebrew-Binary. Nur deutlich sagen, dass das nicht auslieferbar ist.
  echo "WARNUNG: Whisper-Engine wird NICHT mitgeliefert (vendor/whisper-server fehlt)."
  echo "         Diese App läuft nur auf Rechnern mit 'brew install whisper-cpp'."
  echo "         Engine bauen: brew install cmake && bash scripts/build-whisper-engine.sh"
fi

# Finder-Metadaten (xattrs) entfernen - kopierte Bilder bringen welche mit,
# und codesign bricht damit ab ("resource fork ... not allowed").
xattr -cr "$APP"

# Stabile Identität bevorzugen: Ad-hoc-Signierung ("-") erzeugt bei jedem Build
# einen neuen Code-Hash, worauf macOS die Bedienungshilfen-Berechtigung still
# verwirft -> Auto-Einfügen geht kaputt. scripts/make-signing-cert.sh einmal
# ausführen, dann wird hier automatisch stabil signiert.
# Reihenfolge ist Absicht: Ein vorhandenes "FlowWhisper Dev" gewinnt, damit auf
# bestehenden Rechnern die Identität NICHT wechselt - ein Wechsel würde die
# Bedienungshilfen-Berechtigung verwerfen und das Auto-Einfügen zerstören
# (Stolperfalle 1). Nur frische Setups ohne Alt-Zertifikat nehmen "Orbly Dev",
# das make-signing-cert.sh heute anlegt.
# Achtung beim Ändern: Diese Funktion darf NICHT unter `set -e` fehlschlagen.
# `head -1` erzeugte früher SIGPIPE (Exit 141) und ein leeres grep Exit 1 - in
# beiden Fällen brach das Skript bei der Zuweisung unten ohne jede Ausgabe ab
# (genau das passierte beim ersten echten Release-Versuch). Darum `awk NR==1`
# statt `head` und `|| true` an jeder Zuweisung.
find_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "\"$1\"" | awk 'NR==1{print $2}' || true
}
count_identities() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -c -F "\"$1\"" || true
}
if [ -n "${ORBLY_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$ORBLY_SIGN_IDENTITY"
  IDENTITY_HASH="$(find_identity "$IDENTITY" || true)"
  if [ -z "$IDENTITY_HASH" ]; then
    echo "FEHLER: Signier-Identität '$IDENTITY' liegt nicht im Schlüsselbund." >&2
    echo "        Vorhanden sind:" >&2
    security find-identity -v -p codesigning >&2 || true
    exit 1
  fi
  # Zwei Zertifikate mit demselben Namen: make-dmg.sh signiert über den Namen
  # und würde mit "ambiguous" abbrechen, nachdem die App schon signiert ist.
  if [ "$(count_identities "$IDENTITY")" -gt 1 ]; then
    echo "FEHLER: '$IDENTITY' ist mehrfach im Schlüsselbund - das alte Zertifikat entfernen." >&2
    exit 1
  fi
else
  IDENTITY=""
  IDENTITY_HASH=""
  for CANDIDATE in "FlowWhisper Dev" "Orbly Dev"; do
    IDENTITY="$CANDIDATE"
    IDENTITY_HASH="$(find_identity "$CANDIDATE" || true)"
    [ -n "$IDENTITY_HASH" ] && break
  done
fi
if [ -n "$IDENTITY_HASH" ]; then
  case "$IDENTITY" in
  "Developer ID"*)
    # Distribution: Hardened Runtime + Timestamp (Pflicht für Notarisierung).
    # Sparkle-Bestandteile einzeln von innen nach außen signieren (--deep ist
    # dafür ungeeignet und würde die App-Entitlements auf die XPCs vererben).
    echo "==> Codesign Developer ID ($IDENTITY, Hardened Runtime)"
    ENTITLEMENTS="$PROJECT_DIR/Resources/Orbly.entitlements"
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE" ]; then
      SIGNED_NESTED=0
      for NESTED in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app"; do
        if [ -e "$NESTED" ]; then
          # Sparkles XPCs bringen eigene Entitlements mit (Sandbox/Netzwerk) -
          # ohne --preserve-metadata würden sie beim Neusignieren wegfallen.
          codesign --force --options runtime --timestamp \
            --preserve-metadata=entitlements --sign "$IDENTITY_HASH" "$NESTED"
          SIGNED_NESTED=$((SIGNED_NESTED + 1))
        fi
      done
      # Ändert Sparkle sein Bundle-Layout (die Pfade oben sind fest verdrahtet),
      # bliebe sonst still unsigniert, was die Notarisierung ohne klare Ursache
      # ablehnt.
      if [ "$SIGNED_NESTED" -eq 0 ]; then
        echo "FEHLER: keine Sparkle-Bestandteile gefunden - Layout geändert?" >&2
        exit 1
      fi
      codesign --force --options runtime --timestamp --sign "$IDENTITY_HASH" "$SPARKLE"
    fi
    # Mitgelieferte Engine ebenfalls einzeln signieren (von innen nach außen).
    # Ohne Hardened Runtime lehnt die Notarisierung das ganze Bundle ab.
    if [ -f "$APP/Contents/Helpers/whisper-server" ]; then
      codesign --force --options runtime --timestamp \
        --sign "$IDENTITY_HASH" "$APP/Contents/Helpers/whisper-server"
    fi
    codesign --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" --sign "$IDENTITY_HASH" "$APP"
    ;;
  *)
    echo "==> Codesign ($IDENTITY, $IDENTITY_HASH)"
    codesign --force --deep --sign "$IDENTITY_HASH" "$APP"
    ;;
  esac
else
  echo "==> Codesign (ad-hoc) - WARNUNG: Bedienungshilfen-Rechte gehen bei jedem Build verloren."
  echo "    Fix: einmalig 'bash scripts/make-signing-cert.sh' ausführen."
  codesign --force --deep --sign - "$APP"
fi

# Model in den App-Support-Ordner kopieren (einmalig)
MODEL_SRC="$PROJECT_DIR/models/ggml-large-v3-turbo-q5_0.bin"
MODEL_DST="$HOME/Library/Application Support/Orbly/models/ggml-large-v3-turbo-q5_0.bin"
if [ -f "$MODEL_SRC" ] && [ ! -f "$MODEL_DST" ]; then
  echo "==> Kopiere Whisper-Modell nach Application Support"
  mkdir -p "$(dirname "$MODEL_DST")"
  cp "$MODEL_SRC" "$MODEL_DST"
fi

# Installieren. Mit ORBLY_NO_INSTALL=1 nur bauen und signieren: Ein
# Release-Build signiert mit der Developer ID, und die installierte App würde
# damit ihre Identität wechseln. macOS verwirft dann die
# Bedienungshilfen-Berechtigung, und das Auto-Einfügen ist bis zum erneuten
# Erteilen kaputt (Stolperfalle 1). Für Prüfläufe also nicht installieren.
if [ "${ORBLY_NO_INSTALL:-0}" = "1" ]; then
  echo "==> Nicht installiert (ORBLY_NO_INSTALL=1). App liegt in: $APP"
  exit 0
fi

DEST="/Applications/$APP_NAME.app"
if [ -w "/Applications" ]; then
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
else
  DEST="$HOME/Applications/$APP_NAME.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
fi

# Belegen, dass wirklich alles universal ist. Eine einzige arm64-only-Datei im
# Bundle, und die App startet auf einem Intel-Mac gar nicht.
echo "==> Architekturen im Bundle"
for F in "$DEST/Contents/MacOS/$APP_NAME" \
         "$DEST/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
         "$DEST/Contents/Helpers/whisper-server"; do
  if [ -f "$F" ]; then
    ARCHS="$(lipo -archs "$F")"
    printf "    %-16s %s\n" "$(basename "$F")" "$ARCHS"
    case "$ARCHS" in
      *x86_64*arm64*|*arm64*x86_64*) ;;
      *) echo "    FEHLER: $(basename "$F") ist nicht universal." >&2; exit 1 ;;
    esac
  fi
done

echo "==> Installiert: $DEST"
echo "Fertig. Starten mit: open \"$DEST\""
