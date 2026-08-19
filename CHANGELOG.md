# Changelog

Technischer Projekt-Verlauf. **Neueste Einträge oben.** Wer hier neu dazukommt (Mensch
oder Agent) liest diese Datei und die `CLAUDE.md` und ist damit auf Stand.

Pro Eintrag 2 bis 5 Zeilen: Datum, was gemacht, wichtige Entscheidungen, offene Punkte.
Ab ~30 Einträgen die ältere Hälfte nach `docs/changelog-archive.md` verschieben.

---

## 2026-08-19 — Vertriebsstand und Verzeichnis-Einträge

- Am 19.08.2026 in vier Verzeichnisse eingereicht: `jaywcjlove/awesome-swift-macos-apps`
  (gemergt), `jaywcjlove/awesome-mac` PR 2610 (111k Sterne), `serhii-londar/open-source-mac-os-apps`
  PR 1287 (50k), `open-saas-directory/awesome-native-macosx-apps` PR 141.
- README ist jetzt englisch, die deutsche Fassung liegt als `README.de.md`. Beide
  verlinken sich. Zwei Screenshots liegen in `Resources/`, GitHub Discussions ist an.
- Offen und nur von Louis machbar: ein Demo-GIF von 8 bis 10 Sekunden (Fn halten,
  sprechen, Text erscheint). Ohne das funktioniert weder r/macapps noch Show HN.
- Danach: r/macapps zuerst, eine Woche spaeter Show HN. Beides von Hand, automatisierte
  Werbeposts werden dort gelöscht und der Account gesperrt.
- Stand 19.08.2026: 0 Sterne, DMG von v1.1.0 mit 0 Downloads.


## 2026-08-17 (3) — Vollprüfung der App, alle Funde behoben

- **Anlass:** Kompletter Fehler-Check über alle 23 Quelldateien, dazu Skripte, CI und
  Paketierung. Ergebnis waren 5 kritische und 11 wichtige Befunde plus Kleinkram.
  Branch `fix/vollpruefung-1.1.1`, zwei Commits.
- **Die fünf schweren:**
  1. `OverlayController.hide()` setzte `state.phase` nie zurück. Die Punkte-Animation
     lief nach jedem Diktat unsichtbar mit 60 fps weiter, **gemessen 13 % CPU im
     Leerlauf** für den Rest der Sitzung. Behoben, indem `OverlayRootView` seinen
     Inhalt an `state.overlayVisible` bindet. Merksatz: Ein per `orderOut` verstecktes
     Fenster ist für SwiftUI nicht weg.
  2. `noteActivity()` zählte nur den Aufnahme-START. Die Idle-Abschaltung beendete den
     Server nach 3 min mitten im Sprechen, **jedes Diktat über 3 Minuten war komplett
     verloren**, mit Standardeinstellungen. Jetzt hält jeder Pegelwert den Server warm.
  3. `Transcriber.currentTask`/`cancelled` unsynchronisiert und als Schalter statt
     Zähler: Ein abgebrochenes Diktat konnte doch noch hochgeladen werden, ein späteres
     Esc brach den falschen Upload ab. Jetzt Zähler hinter `NSLock`.
  4. `ModelManager.tasks` wurde vom Hauptthread und der URLSession-Queue gleichzeitig
     verändert (Absturzrisiko beim Modell-Download). Jetzt hinter einer Sperre.
  5. `handle.write()` meldet Fehler per NSException, die Swift nicht fangen kann. Eine
     volle Platte beendete die App hart. Jetzt `write(contentsOf:)`.
- **Standardwerte, die aus der Entwicklungszeit stammten:** Diktatsprache stand fest auf
  `de` (jede Installation weltweit bekam Deutsch und das deutsche Fine-Tune empfohlen),
  die Server-Adresse auf `http://ubuntu-server:8643`. Beides korrigiert (`auto` bzw. leer).
  ATS erlaubt weiter beliebige Adressen wegen LAN-Servern, aber für `huggingface.co` und
  den Update-Feed ist TLS jetzt Pflicht.
- **Sonst:** Spenden- und Tour-Fenster werden beim Schließen wirklich freigegeben,
  `MediaController` liest vor `waitUntilExit` (Deadlock-Reihenfolge), mehrfaches
  `[BLANK_AUDIO]` wird entfernt, leeres Ergebnis und abgeschnittene Aufnahmen sagen
  Bescheid (5 Sprachen), Aufnahmepuffer wird geleert, Verlauf/Statistik mit 0600,
  Tastenüberwachung nur noch während eines Diktats, vier Übersetzungsfehler behoben.
- **Zwei Runden Gegenprüfung an den Korrekturen selbst**, beide fündig geworden:
  Codex fand, dass die erste Fassung der `[BLANK_AUDIO]`-Korrektur pauschal jede
  Klammergruppe entfernte („Treffen (verschoben)" hätte den Einschub verloren) und
  ein Race zwischen Generationsprüfung und `task.resume()`. Ein unabhängiger
  Review-Agent fand einen Force-Unwrap (`plotFrame!`, Absturz beim Überfahren des
  Diagramms), dass die `modelPath`-Reparatur hinter dem alten Marker ausgerechnet
  die Betroffenen nie erreicht hätte, und dass die neue Sichtbarkeits-Bindung die
  MTKView pro Diktat neu aufbaut (Shader-Kompilierung auf dem Hauptthread beim
  Fn-Druck, jetzt einmal pro Programmlauf zwischengespeichert). Alles behoben.
- **Geprüft:** `swift build` ohne Warnung, `swift test` 76 grün (15 neu).
  Der Gedankenstrich-Test deckt jetzt den ganzen Quelltext ab statt nur
  `L10n.swift`, genau deshalb waren zwei durchgerutscht; ein zweiter Test verbietet
  `Timer.scheduledTimer` im Quelltext. **Nachgemessen an der installierten App:
  0,0 % CPU im Leerlauf** (vorher 10 bis 14 %).
- **Offen / Nächster Schritt:** Als 1.1.1 releasen. Die Dauerlast und der
  Datenverlust bei langen Diktaten rechtfertigen ein Release für sich allein.
  Nicht gepusht, wartet auf Freigabe.

## 2026-08-17 (2) — Erkennen, dass gar nichts Text annimmt

- **Gemacht:** `TextInserter` prüft vor dem ⌘V, ob im Ziel überhaupt etwas Text annimmt.
  Wenn nicht (Finder, Schreibtisch, native App ohne Textfeld), wird kein ⌘V gesendet,
  der Text bleibt in der Zwischenablage und das Overlay zeigt den Hinweis.
- **Zwei Signale, beide gemessen:** das fokussierte AX-Element (Rolle bzw. beschreibbarer
  Wert) und der Zustand des Menüpunkts mit dem Kürzel ⌘V. Gemessene Werte: Finder liefert
  AXGroup und einen ausgegrauten Menüpunkt, Chrome mit Feld liefert AXTextField.
- **Grenze, bewusst so:** Chromium-Apps (Chrome, Slack, VS Code, Notion) melden auch bei
  aktivem Textfeld kein fokussiertes Element und lassen „Einfügen" immer aktiv. Dort ist
  keine Vorhersage möglich, also wird wie bisher eingefügt. Eine falsche Warnung wäre
  schlimmer als eine fehlende.
- **Datenschutz:** Gelesen werden nur Rolle, Beschreibbarkeit und Menüzustand, nie der
  Inhalt eines Feldes.
- **Geprüft:** `swift build`, `swift test` (61 grün), Verhalten gegen Finder, Chrome,
  Slack, Spotify, Notion und iTerm2 einzeln nachgemessen. Codex-Gegencheck: Timeout pro
  Aufruf auf 0,15 s, Zeitbudget für die Menüsuche, Regler und Schalter ausgeschlossen.

## 2026-08-17 — Hinweis, wenn nichts eingefügt wurde

- **Gemacht:** Konnte der Text nicht eingefügt werden (Bedienungshilfen fehlen oder der
  Nutzer ist inzwischen in einer anderen App), zeigt das Overlay an seiner gewohnten
  Stelle „Nirgendwo eingefügt, Text liegt in der Zwischenablage" (fünf Sprachen).
- **Dazu:** `TextInserter.insert` meldet das Ergebnis jetzt per Completion statt per
  Rückgabewert. Der Fokus kann noch 50 ms vor dem ⌘V wechseln, dieser späte Abbruch war
  vorher gar nicht sichtbar. Die Hinweis-Kapsel bekommt ein eigenes Symbol und wächst
  mit der Textbreite, sonst hätte `lineLimit(1)` den längeren Satz abgeschnitten.
- **Geprüft:** `swift build` und `swift test` (61 grün), signiert installiert.

## 2026-08-08 — Release v1.1.0

- **Gemacht:** Version 1.1.0 (Build 3) gebaut, mit Developer ID signiert, von Apple
  notarisiert und gestapelt, über die Website veröffentlicht (Zip für Sparkle, DMG als
  Erst-Download, `appcast.xml`). Angezeigte Version auf der Website nachgezogen.
- **Dazu:** Das Release-Werkzeug lag bisher nur im alten privaten Repo. `release.sh`,
  `publish-release.sh`, `make-dmg.sh` und `RELEASING.md` liegen jetzt hier, damit ein
  Release aus diesem Repo überhaupt möglich ist. In `RELEASING.md` steht keine
  Apple-ID und keine private Adresse, das gehört nicht in ein öffentliches Repo.
- **Offen / Nächster Schritt:** Update-Weg noch nicht auf einem zweiten Mac getestet.

## 2026-08-08 — Erster Fn-Druck nach langer Pause sagt Bescheid

- **Gemacht:** `AudioRecorder` misst die Aufwachzeit des Starts, `WakeUpPress`
  entscheidet daraus, ob eine zu kurze Aufnahme in Wahrheit nur ein Aufwachdruck war.
  Ist sie das, zeigt das Overlay „Bereit, bitte noch einmal drücken" (fünf Sprachen,
  in der Erst-Tour im Fenster). 4 neue Tests, insgesamt 61 grün.
- **Ursache:** Schläft die Audio-Hardware, blockiert `AVAudioEngine.start()` über eine
  Sekunde. Ein kurzer Fn-Tipp ist dann vorbei, bevor Ton ankommt. Die Aufnahme blieb
  unter der 0,3-s-Grenze und wurde stillschweigend verworfen, für den Nutzer sah es
  aus wie „der erste Druck tut nichts".
- **Entscheidungen:** Auslöser ist allein die gemessene Aufwachzeit. Ein Kaltstart des
  whisper-servers zählt nicht mit, er läuft nebenher und kostet keine Aufnahme. Kein
  Vorwärmen der Audio-Engine: das würde das Mikrofon dauerhaft belegen.
- **Nebenbei behoben:** `serverStarting` wurde bei zu kurzer oder fehlgeschlagener
  Aufnahme nie zurückgesetzt, das Overlay pulsierte danach den Rest der Sitzung.
- **Offen / Nächster Schritt:** Nichts.

## 2026-08-08 — Spendenhinweis eingebaut

- **Gemacht:** Spendenfenster (`Donation.swift`, `DonationView.swift`), Karte „Orbly
  unterstützen" in den Einstellungen, `.github/FUNDING.yml`, README-Abschnitt,
  Übersetzungen in allen fünf Sprachen, 9 neue Tests. Ziel: Ko-fi.
- **Entscheidungen:** Kein Server, keine Lizenzprüfung. Wer „Ich habe gespendet"
  klickt, wird geglaubt. Bei offenem Quellcode wäre jede Prüfung in zwei Minuten
  entfernt, und ein Bezahlserver würde genau die Daten sammeln, die Orbly sonst
  vermeidet. Der Hinweis kommt erst ab 20 Diktaten und danach höchstens alle 14 Tage.
  Der Zähler dafür liegt in den Einstellungen, nicht in der Statistik: die Datei darf
  gelöscht werden und wird asynchron ausgewertet.
- **Offen / Nächster Schritt:** Nichts. `swift test` grün (57 Tests).

## 2026-08-03 — Erste öffentliche Veröffentlichung

- **Gemacht:** Repo von FlowWhisper zu Orbly umbenannt, unter AGPL v3 öffentlich
  gestellt, v1.0.0 als Release mit signierter und notarisierter DMG. Git-Historie
  bereinigt (private E-Mail-Adresse entfernt), Branch-Schutz für `main` eingerichtet,
  Dependabot und GitHub-Actions-CI aktiv.
- **Entscheidungen:** AGPL statt MIT, damit geänderte Versionen und gehostete Dienste
  ihren Quellcode ebenfalls offenlegen müssen.
- **Offen:** Domain `useorbly.com` ist noch nicht registriert, der Download läuft
  weiter über die Vercel-Adresse.
