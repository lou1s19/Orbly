# Publishing a release

Orbly updates itself through [Sparkle](https://sparkle-project.org). The update feed and
the downloads live with the website (`orbly-website`, deployed on Vercel), not on GitHub:
Sparkle has to fetch `appcast.xml` without a login, and download and update should come
from the same address.

Releases are signed with an Apple Developer ID and notarized, so they only work for
whoever holds that certificate. Everything below is written for that person.

## The steps

```bash
# 0. Your signing identity and Apple team. Put them in your shell profile.
export ORBLY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export ORBLY_TEAM_ID="TEAMID"

# 1. Build, sign, notarize, produce zip + DMG + appcast.
#    The identity MUST be set, otherwise you get a test build and
#    publish-release.sh rejects it, correctly.
bash scripts/release.sh 1.1.0

# 2. Publish: copy zip, DMG and appcast into the website repo, commit, push.
#    Vercel deploys automatically. The website repo defaults to
#    ~/Desktop/orbly-website, override it with ORBLY_SITE_REPO.
bash scripts/publish-release.sh 1.1.0 "What is new: …"

# 3. Update the version the website shows:
#    src/lib/site.ts -> downloads.mac.version

# 4. Commit the version bump here and tag it (this is your rollback point):
git add -A && git commit -m "release: v1.1.0" && git tag v1.1.0 && git push --tags origin main
```

## What can go wrong

- **Do not skip step 4.** Sparkle only compares `CFBundleVersion`. If the bump is left
  out, the next release carries the same build number and nobody sees the update.
  `release.sh` checks this against the live feed and aborts otherwise.
- **The private Sparkle key cannot be replaced.** It lives in the keychain only
  ("Private key for signing Sparkle updates"); the public one sits in
  `Resources/Info.plist` as `SUPublicEDKey`. Without the private key no installed copy of
  Orbly will ever get an update again. Export it once and keep it **outside** the repo:
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <path outside the repo>`
- **The feed URL ships inside every released app** and has to stay reachable. When moving
  to another domain, keep serving the old address or redirect it permanently until every
  installation has taken an update that carries the new `SUFeedURL`.
- **Exactly one "Developer ID Application" certificate in the keychain.** With two of the
  same name `codesign` aborts on the DMG with "ambiguous". `build-app.sh` checks for it.
- **Order matters:** upload the files first, then the appcast. `publish-release.sh` does
  both in one commit and verifies beforehand that the appcast points at a file that exists.
- **The update zip is the only channel to existing installations.** If the app inside is
  signed wrong or not notarized, Sparkle rejects the update for good and there is no way
  to repair it. That is why `publish-release.sh` verifies signature, notarization,
  stapling and the universal binary, and aborts otherwise.

## One-time setup

- A Developer ID certificate in the keychain. Without Developer ID and notarization
  Gatekeeper blocks the app on other people's Macs.
- A notarytool profile named `Orbly`:
  `xcrun notarytool store-credentials Orbly --apple-id <apple-id> --team-id "$ORBLY_TEAM_ID"`
  (Careful: the team ID is not the certificate ID of the "Apple Development" certificate.
  With the wrong one notarytool answers `401 Invalid credentials`.)
- The Whisper engine: `brew install cmake && bash scripts/build-whisper-engine.sh`.
  Without `vendor/whisper-server` a release build aborts, because an app without a bundled
  engine is unusable for everyone who does not have Homebrew.

## Check it yourself before publishing

```bash
APP="$HOME/Library/Caches/Orbly/build/Orbly.app"
codesign --verify --deep --strict --verbose=2 "$APP"    # signature complete?
codesign -dv --verbose=4 "$APP" 2>&1 | grep Authority   # Developer ID, not a dev certificate?
spctl -a -t exec -vv "$APP"                             # would Gatekeeper launch it?
```

Test the actual update path: install an older version in a fresh user account or on a
second Mac and click "Check for Updates …". That is the only way to see whether signature
and build number really work for Sparkle.
