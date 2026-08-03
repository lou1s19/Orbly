# Beitragen

Danke, dass du dir das ansiehst. Kurz und schmerzlos:

## Bevor du anfängst

Bei kleinen Fixes einfach einen Pull Request aufmachen. Bei allem, was mehr als eine
Datei anfasst, vorher ein Issue, damit die Arbeit nicht ins Leere läuft.

## Einrichten

```bash
brew install cmake                    # einmalig, für die Whisper-Engine
swift build                           # baut das Paket
swift test                            # 48 Tests
bash scripts/build-app.sh             # baut die App und installiert sie
```

macOS 14 oder neuer. Ein Xcode-Projekt gibt es nicht, alles läuft über SwiftPM.

Hinweis: SourceKit zeigt in diesem Projekt gelegentlich Fehler an, die nicht
existieren („cannot find X in scope"). Maßgeblich ist `swift build`.

## Was die Tests durchsetzen

Zwei Regeln fallen sonst erst dem Nutzer auf, deshalb prüfen sie Tests:

1. **Übersetzungen.** Jeder nutzersichtbare Text gehört nach
   `Sources/Orbly/L10n.swift`, und zwar in **allen fünf** Sprachen (en, de, es, fr,
   ru). Fehlt eine, schlägt `L10nTests` fehl. Auch Platzhalter (`%@`, `%d`) müssen
   in allen Sprachen gleich viele und gleich geordnet sein.
2. **Keine Gedankenstriche** (`–`, `—`) in UI-Texten, auch nicht in Modellnamen.
   Komma, Punkt, Doppelpunkt oder Klammer stattdessen.

## Stil

- Bestehende Muster wiederverwenden statt neue einführen (`cardStyle`,
  `GlassSegmented`, die JSONL-Speicher).
- Kommentare erklären das **Warum**, nicht das Was. Besonders bei allem, was nach
  einem Umweg aussieht: Oft steckt eine macOS-Eigenheit dahinter, und ohne Notiz
  baut der Nächste es „sauber" zurück und der Fehler ist wieder da.
- Kleine Pull Requests. Ein Thema pro PR.

## Vor dem Absenden

`swift build` und `swift test` müssen grün sein. Die CI prüft dasselbe.

Bei Änderungen an der Oberfläche bitte die App wirklich bauen und anklicken.
Ein Diktat lässt sich nicht durch Tests abdecken.
