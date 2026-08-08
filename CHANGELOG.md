# Changelog

Technischer Projekt-Verlauf. **Neueste Einträge oben.** Wer hier neu dazukommt (Mensch
oder Agent) liest diese Datei und die `CLAUDE.md` und ist damit auf Stand.

Pro Eintrag 2 bis 5 Zeilen: Datum, was gemacht, wichtige Entscheidungen, offene Punkte.
Ab ~30 Einträgen die ältere Hälfte nach `docs/changelog-archive.md` verschieben.

---

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
