# Contributing

Thanks for taking a look. Short and painless:

## Before you start

For small fixes just open a pull request. For anything that touches more than one
file, open an issue first so the work does not go to waste.

## Setup

```bash
brew install cmake                    # once, for the Whisper engine
swift build                           # builds the package
swift test                            # runs the test suite
bash scripts/build-app.sh             # builds the app and installs it
```

macOS 14 or newer. There is no Xcode project, everything goes through SwiftPM.

Note: SourceKit occasionally reports errors in this project that do not exist
("cannot find X in scope"). `swift build` is what counts.

## What the tests enforce

Two rules that would otherwise only surface for users, so tests check them:

1. **Translations.** Every user-visible string belongs in
   `Sources/Orbly/L10n.swift`, in **all five** languages (en, de, es, fr, ru).
   If one is missing, `L10nTests` fails. Placeholders (`%@`, `%d`) also have to
   appear the same number of times and in the same order in every language.
2. **No em or en dashes** (`–`, `—`) in UI strings, not even in model names.
   Use a comma, a period, a colon or brackets instead.

## Style

- Reuse existing patterns instead of introducing new ones (`cardStyle`,
  `GlassSegmented`, the JSONL stores).
- Comments explain the **why**, not the what. Especially for anything that looks
  like a detour: there is usually a macOS quirk behind it, and without a note the
  next person "cleans it up" and the bug is back.
- Small pull requests. One topic per PR.

## Before you submit

`swift build` and `swift test` have to be green. CI checks the same.

For changes to the interface, please actually build the app and click through it.
A dictation cannot be covered by tests.
