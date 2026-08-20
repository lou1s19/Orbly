# Reporting a security issue

If you find a security issue, please do **not** open a public issue for it.

Use GitHub's private reporting instead:
[Report a security advisory](https://github.com/lou1s19/Orbly/security/advisories/new)

You will get an answer within a few days. If you want to be credited in the fix,
say so.

## What is security relevant in this project

Orbly needs two far-reaching permissions and processes speech:

- **Accessibility.** Required for the Fn key to work in every app and for pasting
  through a simulated ⌘V. In theory the app could read along with everything you
  type. It does not: the global monitor in `FnKeyMonitor.swift` only forwards the
  `keyCode` and stores nothing.
- **Microphone.** The recording goes to the transcription endpoint as a WAV file
  and is deleted afterwards.
- **Clipboard.** The text is placed there briefly, pasted, and the previous
  content is restored. Dictations are marked with
  `org.nspasteboard.ConcealedType` so clipboard managers do not archive them.

Worth a close look: `TextInserter.swift`, `FnKeyMonitor.swift`,
`LocalServerManager.swift` (starts a subprocess) and `Models.swift` (model
downloads, verified by SHA-256).

## What is not a vulnerability

- In server mode over `http://` the connection is unencrypted. That is known, the
  settings warn about it, and it only affects addresses you entered yourself.
- `NSAllowsArbitraryLoads` is on because users can point the app at any server of
  their own, including inside a VPN. The default is `127.0.0.1`.
