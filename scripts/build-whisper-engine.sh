#!/bin/bash
# Builds the Whisper engine (whisper-server) as ONE self-contained binary that
# ships inside Orbly.app.
#
# Why at all: Orbly used to start the whisper-server from Homebrew. A normal Mac
# user has no Homebrew, so the app was unusable for them.
#
# Why static (BUILD_SHARED_LIBS=OFF) and with an embedded Metal library: the
# Homebrew binary loads its backends at runtime from /opt/homebrew/Cellar/…
# (see `whisper-server --help`: "loaded BLAS backend from …"). Those paths do
# not exist on someone else's Mac. Linked statically and with
# GGML_METAL_EMBED_LIBRARY=ON you get a single file with no external
# dependencies beyond system frameworks, which is exactly what can be signed,
# notarized and shipped.
#
# Usage: bash scripts/build-whisper-engine.sh
# Result: vendor/whisper-server (not in git, rebuilt when needed)
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

# Pinned version. Do not build from master: the engine parses the model files in
# its own process, so you want to know what is in there.
WHISPER_TAG="v1.9.1"

OUT="$PROJECT_DIR/vendor/whisper-server"
# Do not build inside the project folder: it may sit in an iCloud-synced
# location where the file provider stamps FinderInfo xattrs on things that
# codesign later chokes on (the same pitfall as in build-app.sh).
WORK="$HOME/Library/Caches/Orbly/whisper-build"

if ! command -v cmake >/dev/null 2>&1; then
  echo "ERROR: cmake is missing. Install it once with:  brew install cmake" >&2
  exit 1
fi

echo "==> Fetching whisper.cpp $WHISPER_TAG"
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

# Build both architectures separately and merge them afterwards. A single CMake
# run with two architectures fails, because ggml detects different instruction
# set extensions per architecture (NEON versus AVX) and cannot configure both at
# the same time.
SLICES=()
for ARCH in arm64 x86_64; do
  echo "==> Configuring and building for $ARCH (static, Metal embedded)"
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
  [ -n "$SLICE" ] || { echo "ERROR: whisper-server for $ARCH not found." >&2; exit 1; }
  echo "    $ARCH done: $(lipo -archs "$SLICE")"
  SLICES+=("$SLICE")
done

echo "==> Merging into a universal binary"
BIN="$WORK/whisper-server-universal"
lipo -create "${SLICES[@]}" -output "$BIN"
echo "    Architectures: $(lipo -archs "$BIN")"

echo "==> Checking that nothing foreign gets loaded at runtime"
# Only system libraries are allowed. Every line with /opt/homebrew, /usr/local
# or @rpath would be missing on someone else's Mac. Check both architectures.
for ARCH in arm64 x86_64; do
  FOREIGN="$(otool -arch "$ARCH" -L "$BIN" | tail -n +2 | grep -vE '/usr/lib/|/System/' || true)"
  if [ -n "$FOREIGN" ]; then
    echo "ERROR: the $ARCH half links against libraries that only exist here:" >&2
    echo "$FOREIGN" >&2
    echo "       The static build probably did not take effect." >&2
    exit 1
  fi
done

mkdir -p "$PROJECT_DIR/vendor"
cp "$BIN" "$OUT"
chmod +x "$OUT"
# Strip xattrs, otherwise codesign fails in build-app.sh.
xattr -cr "$OUT" 2>/dev/null || true

echo ""
echo "Done: $OUT"
echo "  Size:          $(du -h "$OUT" | cut -f1)"
echo "  Architectures: $(lipo -archs "$OUT")"
echo "  Version:       $WHISPER_TAG"
echo ""
echo "build-app.sh now bundles the binary into the app automatically."
