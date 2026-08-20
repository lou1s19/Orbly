#!/bin/bash
# Builds Orbly.app from the Swift package and installs it.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"
APP_NAME="Orbly"
# Do NOT build inside the project folder: it may sit in an iCloud-synced
# location, where the file provider keeps stamping FinderInfo xattrs onto the
# bundle that codesign then chokes on ("resource fork ... not allowed").
BUILD_DIR="$HOME/Library/Caches/Orbly/build"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/$APP_NAME.app"

# Build universal (Apple Silicon + Intel). With two architectures SwiftPM puts
# the products into .build/apple/Products/Release instead of .build/release.
echo "==> swift build -c release (universal: arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
PRODUCTS=".build/apple/Products/Release"
[ -f "$PRODUCTS/$APP_NAME" ] || { echo "ERROR: $PRODUCTS/$APP_NAME is missing." >&2; exit 1; }

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# Embed the Sparkle framework (auto updates) and set the search path
mkdir -p "$APP/Contents/Frameworks"
cp -R "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Localized permission dialogs (NSMicrophoneUsageDescription and friends).
# macOS reads these from <lang>.lproj/InfoPlist.strings inside the bundle; the
# English text in Info.plist is only the fallback.
for LPROJ in Resources/*.lproj; do
  [ -d "$LPROJ" ] || continue
  mkdir -p "$APP/Contents/Resources/$(basename "$LPROJ")"
  cp "$LPROJ"/*.strings "$APP/Contents/Resources/$(basename "$LPROJ")/"
done

# Logo (sidebar) and app icon from Resources/logo.png, if present
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

# Ship the Whisper engine. Without it the user would need Homebrew, which makes
# the app unusable for everyone who does not have it.
ENGINE="$PROJECT_DIR/vendor/whisper-server"
if [ ! -f "$ENGINE" ] && command -v cmake >/dev/null 2>&1; then
  echo "==> Whisper engine missing, building it (one time, takes a few minutes)"
  bash "$PROJECT_DIR/scripts/build-whisper-engine.sh"
fi
if [ -f "$ENGINE" ]; then
  mkdir -p "$APP/Contents/Helpers"
  cp "$ENGINE" "$APP/Contents/Helpers/whisper-server"
  chmod +x "$APP/Contents/Helpers/whisper-server"
elif [[ "${ORBLY_SIGN_IDENTITY:-}" == "Developer ID"* ]]; then
  # For a release this is a hard error: without the bundled engine every user
  # would need Homebrew, and the app would be unusable for most of them.
  echo "ERROR: the Whisper engine is missing ($ENGINE)." >&2
  echo "       A release without the engine is unusable for anyone without Homebrew." >&2
  echo "       Build it with: brew install cmake && bash scripts/build-whisper-engine.sh" >&2
  exit 1
else
  # Local development build: keep going, the app then falls back to the Homebrew
  # binary. Just say clearly that this build cannot be shipped.
  echo "WARNING: the Whisper engine is NOT bundled (vendor/whisper-server missing)."
  echo "         This app only runs on machines with 'brew install whisper-cpp'."
  echo "         Build the engine: brew install cmake && bash scripts/build-whisper-engine.sh"
fi

# Strip Finder metadata (xattrs). Copied images bring some along and codesign
# aborts on them ("resource fork ... not allowed").
xattr -cr "$APP"

# Prefer a stable identity: ad-hoc signing ("-") produces a new code hash on
# every build, upon which macOS silently drops the accessibility permission and
# auto-insertion breaks. Run scripts/make-signing-cert.sh once and signing here
# becomes stable automatically.
# The order is deliberate: an existing "FlowWhisper Dev" wins so that the
# identity does NOT change on existing machines. A change would drop the
# accessibility permission and destroy auto-insertion (pitfall 1). Only fresh
# setups without the legacy certificate get "Orbly Dev", which is what
# make-signing-cert.sh creates today.
# Careful when changing this: the lookup must NOT fail under `set -e`.
# `head -1` used to produce SIGPIPE (exit 141) and an empty grep exit 1. In both
# cases the script aborted at the assignment below without any output (which is
# exactly what happened on the first real release attempt). Hence `awk NR==1`
# instead of `head`, and `|| true` on every assignment.
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
    echo "ERROR: signing identity '$IDENTITY' is not in the keychain." >&2
    echo "       Available:" >&2
    security find-identity -v -p codesigning >&2 || true
    exit 1
  fi
  # Two certificates with the same name: make-dmg.sh signs by name and would
  # abort with "ambiguous" after the app has already been signed.
  if [ "$(count_identities "$IDENTITY")" -gt 1 ]; then
    echo "ERROR: '$IDENTITY' exists more than once in the keychain, remove the old certificate." >&2
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
    # Distribution: hardened runtime + timestamp (required for notarization).
    # Sign the Sparkle parts individually from the inside out (--deep is unfit
    # for this and would inherit the app entitlements onto the XPCs).
    echo "==> Codesign Developer ID ($IDENTITY, hardened runtime)"
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
          # Sparkle's XPCs carry their own entitlements (sandbox/network).
          # Without --preserve-metadata they would be dropped when re-signing.
          codesign --force --options runtime --timestamp \
            --preserve-metadata=entitlements --sign "$IDENTITY_HASH" "$NESTED"
          SIGNED_NESTED=$((SIGNED_NESTED + 1))
        fi
      done
      # If Sparkle changes its bundle layout (the paths above are hardwired),
      # things would stay silently unsigned, which notarization then rejects
      # without naming a clear cause.
      if [ "$SIGNED_NESTED" -eq 0 ]; then
        echo "ERROR: no Sparkle components found, did the layout change?" >&2
        exit 1
      fi
      codesign --force --options runtime --timestamp --sign "$IDENTITY_HASH" "$SPARKLE"
    fi
    # Sign the bundled engine separately too (inside out). Without the hardened
    # runtime notarization rejects the whole bundle.
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
  echo "==> Codesign (ad-hoc) - WARNING: accessibility permission is lost on every build."
  echo "    Fix: run 'bash scripts/make-signing-cert.sh' once."
  codesign --force --deep --sign - "$APP"
fi

# Copy the model into the Application Support folder (one time)
MODEL_SRC="$PROJECT_DIR/models/ggml-large-v3-turbo-q5_0.bin"
MODEL_DST="$HOME/Library/Application Support/Orbly/models/ggml-large-v3-turbo-q5_0.bin"
if [ -f "$MODEL_SRC" ] && [ ! -f "$MODEL_DST" ]; then
  echo "==> Copying the Whisper model into Application Support"
  mkdir -p "$(dirname "$MODEL_DST")"
  cp "$MODEL_SRC" "$MODEL_DST"
fi

# Install. With ORBLY_NO_INSTALL=1 only build and sign: a release build is
# signed with the Developer ID, and the installed app would change its identity
# through it. macOS then drops the accessibility permission and auto-insertion
# is broken until it is granted again (pitfall 1). So do not install for
# verification runs.
if [ "${ORBLY_NO_INSTALL:-0}" = "1" ]; then
  echo "==> Not installed (ORBLY_NO_INSTALL=1). The app is at: $APP"
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

# Prove that everything really is universal. A single arm64-only file in the
# bundle and the app will not even launch on an Intel Mac.
echo "==> Architectures in the bundle"
for F in "$DEST/Contents/MacOS/$APP_NAME" \
         "$DEST/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
         "$DEST/Contents/Helpers/whisper-server"; do
  if [ -f "$F" ]; then
    ARCHS="$(lipo -archs "$F")"
    printf "    %-16s %s\n" "$(basename "$F")" "$ARCHS"
    case "$ARCHS" in
      *x86_64*arm64*|*arm64*x86_64*) ;;
      *) echo "    ERROR: $(basename "$F") is not universal." >&2; exit 1 ;;
    esac
  fi
done

echo "==> Installed: $DEST"
echo "Done. Launch it with: open \"$DEST\""
