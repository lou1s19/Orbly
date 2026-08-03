# Orbly

Diktier-App für macOS. Fn-Taste halten, sprechen, loslassen, der Text landet an der
Cursor-Position. Transkribiert wird auf dem eigenen Mac mit
[whisper.cpp](https://github.com/ggml-org/whisper.cpp), optional über einen eigenen
Server im Heimnetz.

**Download der fertigen App:** [orbly-website.vercel.app](https://orbly-website.vercel.app)

**Deine Aufnahmen und Texte verlassen den Mac nicht.** Ins Netz geht Orbly nur an drei
Stellen: an deinen Transkriptions-Endpunkt (standardmäßig `127.0.0.1`), einmalig an
`huggingface.co` beim Herunterladen eines Sprachmodells und an die Update-Prüfung.
Kein Konto, keine Telemetrie, keine Analyse. Der Code hier ist der Beleg dafür.

## Bedienung

| Aktion | Wirkung |
|---|---|
| **Fn halten** | Push-to-talk: aufnehmen solange gedrückt, beim Loslassen wird transkribiert |
| **Fn kurz tippen** | Aufnahme startet und läuft weiter; erneut tippen beendet sie |
| **Esc** | Aufnahme abbrechen, auch während der Verarbeitung |

## Voraussetzungen

- macOS 14+, Apple Silicon und Intel (Universal Binary)
- Sonst nichts. Die Whisper-Engine liegt in der App, das Sprachmodell lädt sie beim
  ersten Start herunter.

## Selbst bauen

```bash
brew install cmake                    # einmalig, für die Engine
bash scripts/make-signing-cert.sh     # einmalig, stabiles Signier-Zertifikat
bash scripts/build-app.sh             # baut Engine + App, installiert nach /Applications
```

Ohne eigenes Zertifikat wird ad-hoc signiert. Dann verwirft macOS die
Bedienungshilfen-Berechtigung bei **jedem** Neubau und das automatische Einfügen
funktioniert nicht mehr, bis sie neu erteilt wird. Deshalb der zweite Schritt.

Die Engine (`whisper-server` aus whisper.cpp) wird von
`scripts/build-whisper-engine.sh` statisch gebaut und landet in `Contents/Helpers/`
im App-Bundle. Sie hat keine Abhängigkeit auf Homebrew, damit die App auf jedem Mac
läuft. Das Skript prüft das nach dem Bauen selbst.

Beim ersten Start:

1. **Mikrofon** erlauben
2. **Bedienungshilfen** erlauben (Systemeinstellungen → Datenschutz & Sicherheit →
   Bedienungshilfen), nötig für die Fn-Taste und das Einfügen
3. Systemeinstellungen → Tastatur → „Fn-Taste drücken für" → **„Keine Aktion"**,
   sonst öffnet macOS Emoji oder die eigene Diktierfunktion

## Tests

```bash
swift test
```

48 Tests. Abgedeckt ist bewusst das, was in der Vergangenheit wirklich kaputtgegangen
ist: der Zusammenbau der Whisper-Segmente (dort entstanden Lücken mitten im Wort), die
Statistik-Rechnung samt Verdichtung, der Gleichstand der fünf Sprachtabellen inklusive
Platzhalter, und der Modell-Katalog mit seinen Prüfsummen. Ein Test schlägt fehl, wenn
jemand ein Textfeld in die Statistik einbaut, damit bleibt das Datenschutz-Versprechen
überprüfbar statt behauptet.

## Architektur

- Swift-Menüleisten-App (SwiftPM, kein Xcode-Projekt nötig)
- Fn-Erkennung über `NSEvent`-Monitore (`flagsChanged`, keyCode 63)
- Aufnahme: `AVAudioEngine` → 16 kHz mono WAV
- Transkription: HTTP-POST an `whisper-server` (`/inference`), lokal oder remote;
  OpenAI-kompatible Endpunkte funktionieren ebenfalls
- Einfügen: Zwischenablage + simuliertes ⌘V, danach wird die Zwischenablage
  wiederhergestellt
- Alle UI-Texte in `Sources/Orbly/L10n.swift`, fünf Sprachen (en, de, es, fr, ru)

## Beitragen

Fehlerberichte und Pull Requests sind willkommen. Zwei Bitten:

- Vor einem größeren Umbau kurz ein Issue aufmachen, damit die Arbeit nicht ins Leere
  läuft.
- Neue nutzersichtbare Texte gehören nach `L10n.swift` in **allen fünf** Sprachen,
  sonst schlagen die Tests fehl. Und keine Gedankenstriche in UI-Texten, das prüft
  ein Test ebenfalls.

`swift build` und `swift test` müssen grün sein, das prüft die CI auch selbst.

## Lizenz

[GNU AGPL v3](LICENSE). Kurz gesagt: Du darfst den Code benutzen, ändern und
weitergeben, aber wenn du eine geänderte Version verbreitest oder als Dienst
anbietest, muss dein Quellcode ebenfalls unter der AGPL offen liegen.

Die fertige, signierte und von Apple beglaubigte App gibt es über die Website. Falls
später kostenpflichtige Zusatzfunktionen dazukommen, liegen die außerhalb dieses
Repos. Alles, was hier liegt, bleibt unter der AGPL.
