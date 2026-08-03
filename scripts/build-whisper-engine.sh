#!/bin/bash
# Baut die Whisper-Engine (whisper-server) als EIN eigenständiges Binary, das in
# Orbly.app mitgeliefert wird.
#
# Warum überhaupt: Vorher startete Orbly den whisper-server aus Homebrew. Ein
# normaler Mac-Nutzer hat kein Homebrew, für den war die App damit unbenutzbar.
#
# Warum statisch (BUILD_SHARED_LIBS=OFF) und mit eingebetteter Metal-Bibliothek:
# Das Homebrew-Binary lädt seine Backends zur Laufzeit aus /opt/homebrew/Cellar/…
# nach (siehe `whisper-server --help`: "loaded BLAS backend from …"). Diese Pfade
# gibt es auf einem fremden Mac nicht. Statisch gelinkt und mit
# GGML_METAL_EMBED_LIBRARY=ON entsteht eine einzige Datei ohne externe
# Abhängigkeiten außer System-Frameworks - genau das, was man signieren,
# notarisieren und ausliefern kann.
#
# Nutzung: bash scripts/build-whisper-engine.sh
# Ergebnis: vendor/whisper-server (nicht im Git, wird bei Bedarf neu gebaut)
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

# Feste Version. Nicht auf master bauen: Die Engine parst die Modelldateien im
# eigenen Prozess, da will man wissen, was drin ist.
WHISPER_TAG="v1.9.1"

OUT="$PROJECT_DIR/vendor/whisper-server"
# Nicht im Projektordner bauen: Der Desktop ist iCloud-synchronisiert und der
# File-Provider stempelt FinderInfo-xattrs auf, an denen später codesign
# scheitert (dieselbe Stolperfalle wie bei build-app.sh).
WORK="$HOME/Library/Caches/Orbly/whisper-build"

if ! command -v cmake >/dev/null 2>&1; then
  echo "FEHLER: cmake fehlt. Einmalig installieren mit:  brew install cmake" >&2
  exit 1
fi

echo "==> whisper.cpp $WHISPER_TAG holen"
mkdir -p "$WORK"
SRC="$WORK/whisper.cpp"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --depth 1 origin "refs/tags/$WHISPER_TAG:refs/tags/$WHISPER_TAG" 2>/dev/null || true
  git -C "$SRC" checkout -q "$WHISPER_TAG"
else
  rm -rf "$SRC"
  git clone --depth 1 --branch "$WHISPER_TAG" \
    https://github.com/ggml-org/whisper.cpp.git "$SRC"
fi
echo "    Commit: $(git -C "$SRC" rev-parse HEAD)"

# Beide Architekturen getrennt bauen und danach zusammenfügen. Ein einzelner
# CMake-Lauf mit zwei Architekturen scheitert, weil ggml pro Architektur andere
# Befehlssatz-Erweiterungen erkennt (NEON gegen AVX) und das nicht gleichzeitig
# konfigurieren kann.
SLICES=()
for ARCH in arm64 x86_64; do
  echo "==> Konfigurieren und bauen für $ARCH (statisch, Metal eingebettet)"
  BUILD="$WORK/build-$ARCH"
  rm -rf "$BUILD"
  cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_BLAS=OFF \
    -DGGML_NATIVE=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON \
    >/dev/null
  cmake --build "$BUILD" --config Release --target whisper-server -j"$(sysctl -n hw.ncpu)" >/dev/null
  SLICE="$(find "$BUILD" -type f -name whisper-server -perm +111 | head -1)"
  [ -n "$SLICE" ] || { echo "FEHLER: whisper-server für $ARCH nicht gefunden." >&2; exit 1; }
  echo "    $ARCH fertig: $(lipo -archs "$SLICE")"
  SLICES+=("$SLICE")
done

echo "==> Zu einem Universal-Binary zusammenfügen"
BIN="$WORK/whisper-server-universal"
lipo -create "${SLICES[@]}" -output "$BIN"
echo "    Architekturen: $(lipo -archs "$BIN")"

echo "==> Prüfen, dass wirklich nichts Fremdes nachgeladen wird"
# Nur System-Bibliotheken sind erlaubt. Jede Zeile mit /opt/homebrew, /usr/local
# oder @rpath würde auf einem fremden Mac fehlen. Beide Architekturen prüfen.
for ARCH in arm64 x86_64; do
  FREMD="$(otool -arch "$ARCH" -L "$BIN" | tail -n +2 | grep -vE '/usr/lib/|/System/' || true)"
  if [ -n "$FREMD" ]; then
    echo "FEHLER: Die $ARCH-Hälfte hängt an Bibliotheken, die es nur hier gibt:" >&2
    echo "$FREMD" >&2
    echo "        Vermutlich hat der statische Build nicht gegriffen." >&2
    exit 1
  fi
done

mkdir -p "$PROJECT_DIR/vendor"
cp "$BIN" "$OUT"
chmod +x "$OUT"
# xattrs entfernen, sonst scheitert codesign in build-app.sh.
xattr -cr "$OUT" 2>/dev/null || true

echo ""
echo "Fertig: $OUT"
echo "  Größe:      $(du -h "$OUT" | cut -f1)"
echo "  Architekturen: $(lipo -archs "$OUT")"
echo "  Version:     $WHISPER_TAG"
echo ""
echo "build-app.sh legt das Binary jetzt automatisch mit in die App."
