#!/bin/bash
# Builds a release: set the version, build, sign the update zip, generate appcast.xml.
# Usage: bash scripts/release.sh 1.1.0
# Then publish it: bash scripts/publish-release.sh 1.1.0 "<what is new>" (see RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: bash scripts/release.sh <version, e.g. 1.1.0>}"
# Downloads and the update feed live with the website (Vercel), not on GitHub.
# Careful: this feed address ships inside every released app. It has to STAY
# reachable, also after a move to another domain. Set up a redirect there.
SITE_BASE="https://orbly-website.vercel.app"
REPO_DL="$SITE_BASE/download/"
FEED_URL="$SITE_BASE/appcast.xml"

# If the run aborts (missing certificate, notarization fails), Info.plist would
# otherwise be left behind in the working tree with a bumped build number.
PLIST_BAK="$(mktemp)"
cp Resources/Info.plist "$PLIST_BAK"
trap '[ "$?" -eq 0 ] || { cp "$PLIST_BAK" Resources/Info.plist; echo "Aborted, Info.plist restored."; }; rm -f "$PLIST_BAK"' EXIT

echo "==> Setting version $VERSION in Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
BUILD_NUM="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
BUILD_NUM=$((BUILD_NUM + 1))
plutil -replace CFBundleVersion -string "$BUILD_NUM" Resources/Info.plist
echo "    Build number: $BUILD_NUM"

# Sparkle compares the build number ONLY. If the version bump was not committed
# after an earlier release, the same number is produced twice. No user sees the
# update and nothing raises an alarm.
# That mistake has no repair path, so do NOT silently skip the check when the
# feed is unreachable. A 404 on the other hand is the normal state before the
# very first release: there is no appcast yet.
FEED_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$FEED_URL" || echo "000")"
if [ "$FEED_CODE" = "404" ]; then
  echo "    No published feed yet (HTTP 404), so this is the first release. Check skipped."
elif FEED_XML="$(curl -fsSL "$FEED_URL" 2>&1)"; then
  LIVE_BUILD="$(printf '%s' "$FEED_XML" | tr '>' '>\n' \
    | sed -n 's/.*<sparkle:version[^>]*>\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1 || true)"
  if [ -n "$LIVE_BUILD" ] && [ "$BUILD_NUM" -le "$LIVE_BUILD" ]; then
    echo "ERROR: build number $BUILD_NUM is not higher than the published one ($LIVE_BUILD)." >&2
    echo "       The last version bump was never committed. Set CFBundleVersion in" >&2
    echo "       Resources/Info.plist to at least $((LIVE_BUILD + 1)) and commit it." >&2
    exit 1
  fi
  echo "    Published build number in the feed: ${LIVE_BUILD:-none yet}"
elif [ "${ORBLY_SKIP_BUILD_CHECK:-0}" = "1" ]; then
  echo "    WARNING: feed unreachable, build number check skipped (ORBLY_SKIP_BUILD_CHECK=1)."
else
  echo "ERROR: the update feed is unreachable, the build number cannot be checked." >&2
  echo "       Response: $(printf '%s' "$FEED_XML" | tail -1)" >&2
  echo "       A duplicate build number means nobody sees the update, and that cannot" >&2
  echo "       be repaired afterwards. Either go online or override deliberately with:" >&2
  echo "       ORBLY_SKIP_BUILD_CHECK=1 bash scripts/release.sh $VERSION" >&2
  exit 1
fi

echo "==> Building the app"
# Do NOT install: a release is signed with the Developer ID. Overwriting the
# installed app with it changes its identity, and macOS drops the accessibility
# permission. The everyday app stays on the dev certificate, the release
# artifact lands in ~/Library/Caches.
ORBLY_NO_INSTALL=1 bash scripts/build-app.sh

RELEASE_DIR="$HOME/Library/Caches/Orbly/releases"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
APP_PATH="$HOME/Library/Caches/Orbly/build/Orbly.app"
ZIP="$RELEASE_DIR/Orbly-$VERSION.zip"

# IMPORTANT: notarize and staple first, THEN pack the update zip.
# The zip is what every existing installation downloads and installs through
# Sparkle. Earlier only the DMG was notarized, so the zip held an app without a
# notarization ticket.
if [[ "${ORBLY_SIGN_IDENTITY:-}" == "Developer ID"* ]]; then
  if NOTARY_CHECK="$(xcrun notarytool history --keychain-profile Orbly 2>&1)"; then
    echo "==> Notarizing the app with Apple (usually 1-5 minutes) …"
    UPLOAD_ZIP="$RELEASE_DIR/notarize-upload.zip"
    ditto -c -k --keepParent "$APP_PATH" "$UPLOAD_ZIP"
    xcrun notarytool submit "$UPLOAD_ZIP" --keychain-profile Orbly --wait
    rm -f "$UPLOAD_ZIP"
    xcrun stapler staple "$APP_PATH"
    echo "==> App notarized and stapled"
  else
    echo "ERROR: notarytool profile 'Orbly' is not usable. Apple says:" >&2
    echo "$NOTARY_CHECK" | tail -3 >&2
    echo "       Set it up with: xcrun notarytool store-credentials Orbly --apple-id <apple-id> --team-id \"\$ORBLY_TEAM_ID\"" >&2
    exit 1
  fi
else
  echo "Note: without ORBLY_SIGN_IDENTITY this produces a test release for this Mac only"
  echo "      (not notarized, publish-release.sh will reject it)."
fi

echo "==> Packing the update zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

echo "==> Signing and generating appcast.xml (EdDSA key from the keychain)"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast "$RELEASE_DIR" \
  --download-url-prefix "$REPO_DL" \
  --maximum-versions 1

echo "==> Building the DMG (first-time download / website)"
bash scripts/make-dmg.sh "$RELEASE_DIR"

echo ""
echo "Built and signed. Next steps (details in RELEASING.md):"
echo "  1. bash scripts/publish-release.sh $VERSION '<what is new>'"
echo "  2. git add -A && git commit -m 'release: v$VERSION' && git tag v$VERSION && git push --tags origin main"
