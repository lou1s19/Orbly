# Changelog

All notable changes to Orbly. Newest first. This project follows
[semantic versioning](https://semver.org).

## [1.1.2] - 2026-08-20

### Fixed
- Windows opened tucked under the menu bar instead of in the middle of the
  screen, and on a wide screen they hung over the right edge. This affected the
  first-run tour, the settings and the donation window.
- With more than one monitor, windows opened on the screen carrying the menu bar
  instead of the one you are working on.

## [1.1.1] - 2026-08-20

### Added
- The dictation key can be changed. Fn stays the default, but you can move
  dictation to the right Command, Option or Control key. macOS uses Fn to switch
  the input source, which made Orbly awkward for anyone typing in more than one
  language (#2). The menu, the overlay and the first-run tour name the key you
  picked.

### Fixed
- Orbly kept using 10 to 14 % CPU after every dictation for the rest of the
  session. An invisible animation went on running at 60 fps behind a hidden
  window. Idle usage is back to 0 %.
- Any dictation longer than three minutes was lost. The idle shutdown only
  counted the start of a recording, so it stopped the local server while you
  were still speaking. Audio levels now keep the server awake.
- A cancelled dictation could still be uploaded, and a later Esc could cancel
  the wrong upload.
- Downloading a model could crash the app.
- A full disk terminated the app instead of reporting the error.
- Crash when moving the pointer over the statistics chart.
- The donation and tour windows were not released when closed.
- Repeated `[BLANK_AUDIO]` markers are removed from the transcript. Text in
  brackets that you actually dictated is kept.
- Four wrong translations.

### Changed
- The dictation language now defaults to automatic detection instead of German,
  and the server address field starts empty.
- Empty results and recordings that were cut short now say so instead of
  failing silently.
- History and statistics files are created with owner-only permissions.
- Key monitoring only runs during a dictation, not while you type elsewhere.
- TLS is now required for model downloads and the update feed. Custom server
  addresses can still use plain HTTP for machines on your own network.
- The DMG opens as an installer window that points from the app to the
  Applications folder, instead of a plain folder with two icons in it.

### Added
- Orbly tells you when the text could not be pasted anywhere, for example when
  accessibility permission is missing or you switched apps in the meantime. The
  text stays in the clipboard.
- Before pasting, Orbly checks whether the target accepts text at all. In the
  Finder, on the desktop and in native apps without a text field it no longer
  sends ⌘V. Chromium based apps (Chrome, Slack, VS Code, Notion) do not report
  this reliably, so there Orbly pastes as before.

## [1.1.0] - 2026-08-08

### Added
- The first Fn press after a long pause now says "Ready, press again". The audio
  hardware needs about a second to wake up, so a short press used to produce
  nothing and looked broken.
- Donation window and a support card in the settings, linking to Ko-fi. Orbly
  asks once after 20 dictations and then at most every 14 days. There is no
  check and no server behind it.

### Fixed
- The overlay kept pulsing for the rest of the session after a recording that
  was too short or that failed.

## [1.0.0] - 2026-08-03

First public release. Local dictation for macOS: hold Fn, speak, and the text
lands at the cursor. Transcription runs on your Mac through whisper.cpp, or
against a server you run yourself. No account, no telemetry.

- Signed and notarized DMG, automatic updates through Sparkle.
- Interface in English, German, Spanish, French and Russian.
- Released under AGPL v3.

[1.1.2]: https://github.com/lou1s19/Orbly/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/lou1s19/Orbly/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/lou1s19/Orbly/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/lou1s19/Orbly/releases/tag/v1.0.0
