# CLAUDE.md

Projektregeln für Claude Code. Verlauf und Stand stehen in der `CHANGELOG.md`.

## Was das ist

Orbly ist eine native macOS-Diktier-App: Fn halten, sprechen, loslassen, der Text landet
an der Cursor-Position. Transkribiert wird lokal mit whisper.cpp oder auf einem eigenen
Server. Kein Konto, keine Telemetrie. Menüleisten-App ohne Dock-Symbol.

- **Stack:** Swift, SwiftUI und AppKit, gebaut mit SwiftPM (kein Xcode-Projekt).
  Metal fürs Overlay, Swift Charts für die Statistik, Sparkle für Updates.
- **Lizenz:** AGPL v3. Die ganze App liegt in diesem Repo, es gibt keine geschlossenen
  Teile. Finanziert über freiwillige Spenden (Ko-fi, siehe `Donation.swift`).
- **Ziel:** macOS 14 oder neuer, Universal Binary.

## Befehle

```bash
swift build                           # baut die App
swift test                            # alle Tests
brew install cmake                    # einmalig, für die Whisper-Engine
bash scripts/make-signing-cert.sh     # einmalig, stabiles Signier-Zertifikat
bash scripts/build-app.sh             # Engine + App bauen, nach /Applications installieren
```

Ohne eigenes Zertifikat wird ad-hoc signiert, und dann verwirft macOS die
Bedienungshilfen-Berechtigung bei jedem Neubau.

## Zwei Regeln, die die Tests erzwingen

1. **Jeder nutzersichtbare Text gehört nach `Sources/Orbly/L10n.swift`, in allen fünf
   Sprachen** (en, de, es, fr, ru). Gleiche Schlüssel, gleiche Platzhalter, nichts leer,
   nichts unübersetzt aus dem Englischen kopiert.
2. **Keine Gedankenstriche** (– und —) in UI-Texten. Punkt, Komma, Doppelpunkt oder
   Klammer stattdessen. Bindestriche in zusammengesetzten Wörtern sind erlaubt.

## Arbeitsweise

- Bestehende Struktur und Namensgebung erst lesen, dann ändern. Kommentare in diesem
  Projekt erklären das **Warum**, nicht das Was. Diesen Ton halten.
- Funktionierenden Code nicht anfassen, nur den minimalen Diff für die Aufgabe.
- Vor „fertig": `swift build` und `swift test` müssen durchlaufen.
- Größere Änderungen auf einem Feature-Branch, nie direkt auf `main` (dort greift ein
  Branch-Schutz). Bei paralleler Arbeit im selben Repo ein `git worktree` nutzen.

## Datenschutz ist hier eine Produkteigenschaft

Orbly verspricht, dass Aufnahmen und Texte den Mac nicht verlassen. Ins Netz geht die
App an genau drei Stellen: `127.0.0.1` (lokale Engine), `huggingface.co` (einmaliger
Modell-Download) und der Update-Feed. **Keine weitere Netzverbindung ohne ausdrückliche
Ansage**, keine Telemetrie, keine Analyse, keine Gerätekennung.

Die Statistik speichert nur Zahlen, nie Text. Ein Test schlägt fehl, wenn jemand ein
Textfeld einbaut. Der Verlauf ist abschaltbar, löschbar und altert nach drei Tagen aus.

## Sicherheit

- Signier-Schlüssel liegen im Schlüsselbund, nie im Repo. `.env`, `*.p12`, `*.pem` und
  `sparkle_private_key*` sind gitignored und bleiben es.
- Der private Sparkle-Schlüssel ist unersetzlich: Geht er verloren, bekommt keine
  installierte Orbly je wieder ein Update.
- Keine Deployments, Releases oder Historien-Umschreibungen ohne Rückfrage.
