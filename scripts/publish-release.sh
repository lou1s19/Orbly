#!/bin/bash
# Publishes a release built by release.sh through the WEBSITE (Vercel):
#   1. put the update zip, the DMG and appcast.xml into the website repo
#   2. commit and push -> Vercel deploys -> download and update are live
#
# Why through the website and not through GitHub releases: the download button
# and the update feed then come from the same address, and the file names stay
# stable (public/download/Orbly.dmg). A GitHub release is possible on top of
# that, but it is not the channel Sparkle polls.
#
# Usage: bash scripts/publish-release.sh 1.1.0 "What is new ..."
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: bash scripts/publish-release.sh <version> [release-notes]}"
NOTES="${2:-Orbly $VERSION}"
RELEASE_DIR="$HOME/Library/Caches/Orbly/releases"
SITE_REPO="${ORBLY_SITE_REPO:-$HOME/Desktop/orbly-website}"
SITE_BASE="${ORBLY_SITE_BASE:-https://orbly-website.vercel.app}"
ZIP="$RELEASE_DIR/Orbly-$VERSION.zip"
DMG="$RELEASE_DIR/Orbly-$VERSION.dmg"
APPCAST="$RELEASE_DIR/appcast.xml"

[ -f "$ZIP" ] || { echo "Missing: $ZIP - run 'bash scripts/release.sh $VERSION' first."; exit 1; }
[ -f "$APPCAST" ] || { echo "Missing: $APPCAST - run 'bash scripts/release.sh $VERSION' first."; exit 1; }
[ -d "$SITE_REPO/.git" ] || { echo "Website repo not found: $SITE_REPO"; exit 1; }

# ---------------------------------------------------------------------------
# Safety gate for the update zip.
#
# This is how existing installations get updated. If the app inside does not
# satisfy Gatekeeper, or the signing identity changes, Sparkle rejects the
# update for good, and there is no second channel to repair that. So check it
# hard, not just the DMG.
# ---------------------------------------------------------------------------
ZIP_CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$ZIP_CHECK_DIR"' EXIT
ditto -x -k "$ZIP" "$ZIP_CHECK_DIR"
ZIP_APP="$ZIP_CHECK_DIR/Orbly.app"
[ -d "$ZIP_APP" ] || { echo "ABORT: $ZIP does not contain an Orbly.app."; exit 1; }

ZIP_OK=1
xcrun stapler validate "$ZIP_APP" >/dev/null 2>&1 || ZIP_OK=0
spctl -a -t exec -vv "$ZIP_APP" >/dev/null 2>&1 || ZIP_OK=0
# NO `| grep -q` here: grep closes the pipe after the first match, codesign gets
# SIGPIPE (exit 141), and `pipefail` turns that into a failure. The gate would
# then reject a perfectly correct release (which is exactly what happened on
# 2026-08-03). Collect the output first, then inspect it.
CODESIGN_OUT="$(codesign -dv --verbose=4 "$ZIP_APP" 2>&1 || true)"
case "$CODESIGN_OUT" in
  *"Authority=Developer ID Application"*) ;;
  *) ZIP_OK=0 ;;
esac
# Universal: an arm64-only app does not even launch on Intel Macs.
for F in "$ZIP_APP/Contents/MacOS/Orbly" \
         "$ZIP_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
         "$ZIP_APP/Contents/Helpers/whisper-server"; do
  [ -f "$F" ] || { echo "ABORT: $F is missing from the zip."; exit 1; }
  case "$(lipo -archs "$F")" in
    *x86_64*arm64*|*arm64*x86_64*) ;;
    *) echo "ABORT: $(basename "$F") in the zip is not universal."; exit 1 ;;
  esac
done

if [ "$ZIP_OK" != "1" ]; then
  if [ "${ORBLY_ALLOW_UNNOTARIZED:-0}" = "1" ]; then
    echo "WARNING: the update zip is not notarized or not signed with a Developer ID."
    echo "         Publishing anyway because ORBLY_ALLOW_UNNOTARIZED=1."
  else
    echo "ABORT: the app in the update zip is not Developer ID signed, notarized and"
    echo "       stapled. Sparkle would reject this update for every user and the"
    echo "       mistake could not be repaired. Details:"
    printf '%s\n' "$CODESIGN_OUT" | grep -E "Authority|Identifier" || true
    spctl -a -t exec -vv "$ZIP_APP" 2>&1 | tail -2 || true
    echo "       Build it properly with:"
    echo "       ORBLY_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" bash scripts/release.sh $VERSION"
    exit 1
  fi
fi

if [ -f "$DMG" ]; then
  if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    if [ "${ORBLY_ALLOW_UNNOTARIZED:-0}" != "1" ]; then
      echo "ABORT: $DMG is not notarized/stapled, Gatekeeper would block it."
      exit 1
    fi
    echo "WARNING: DMG not notarized, uploading anyway because ORBLY_ALLOW_UNNOTARIZED=1."
  fi
fi

# ---------------------------------------------------------------------------
# Put it into the website
# ---------------------------------------------------------------------------
DL_DIR="$SITE_REPO/public/download"
mkdir -p "$DL_DIR"

echo "==> Removing old versions from the website (keeps that repo small)"
# Only the current version needs to sit there: the appcast advertises the newest
# one anyway (--maximum-versions 1), and the download button points at Orbly.dmg.
find "$DL_DIR" -maxdepth 1 -type f \( -name 'Orbly-*.zip' -o -name 'Orbly-*.dmg' \) -delete

echo "==> Copying files"
cp "$ZIP" "$DL_DIR/"
[ -f "$DMG" ] && cp "$DMG" "$DL_DIR/"
# Fixed name for the website's download button, so nothing has to be touched
# there per release.
[ -f "$DMG" ] && cp "$DMG" "$DL_DIR/Orbly.dmg"
# The appcast sits at the root: https://<site>/appcast.xml
cp "$APPCAST" "$SITE_REPO/public/appcast.xml"

echo "==> Verifying that the appcast points at files that exist"
# A typo in the path would mean Sparkle downloads into the void.
ENCL="$(grep -o 'url="[^"]*"' "$SITE_REPO/public/appcast.xml" | head -1 | sed 's/url="//;s/"//')"
ENCL_FILE="$(basename "$ENCL")"
[ -f "$DL_DIR/$ENCL_FILE" ] || {
  echo "ABORT: the appcast references '$ENCL_FILE', but that file is not in public/download/."
  exit 1
}

echo "==> Committing and pushing the website (Vercel deploys automatically)"
cd "$SITE_REPO"
BRANCH="$(git branch --show-current)"
git add public/download public/appcast.xml
if git diff --staged --quiet; then
  echo "    No changes, nothing to push."
else
  git commit -q -m "release: Orbly $VERSION

$NOTES"
  git push origin "$BRANCH"
fi

echo ""
echo "Published through the website."
echo "  Download:    $SITE_BASE/download/Orbly.dmg"
echo "  Update feed: $SITE_BASE/appcast.xml"
echo ""
echo "Vercel needs a minute or two to deploy. Then check:"
echo "  curl -sI $SITE_BASE/appcast.xml | head -1"
echo ""
echo "Do not forget: commit the version bump in the app repo and set tag v$VERSION."
