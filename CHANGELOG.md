# Changelog

Technischer Projekt-Verlauf. **Neueste Einträge oben.** Wer hier neu dazukommt (Mensch
oder Agent) liest diese Datei und die `CLAUDE.md` und ist damit auf Stand.

Pro Eintrag 2 bis 5 Zeilen: Datum, was gemacht, wichtige Entscheidungen, offene Punkte.
Ab ~30 Einträgen die ältere Hälfte nach `docs/changelog-archive.md` verschieben.

---

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
