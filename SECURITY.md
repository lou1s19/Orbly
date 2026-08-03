# Sicherheitslücken melden

Wenn du eine Sicherheitslücke findest, mach dafür **kein öffentliches Issue** auf.

Nutze stattdessen die private Meldefunktion von GitHub:
[Security Advisory melden](https://github.com/lou1s19/orbly-mac/security/advisories/new)

Ich melde mich innerhalb weniger Tage. Wenn du möchtest, wirst du im Fix genannt.

## Was in diesem Projekt sicherheitsrelevant ist

Orbly braucht zwei Berechtigungen, die weit reichen, und verarbeitet Sprache:

- **Bedienungshilfen.** Nötig für die Fn-Taste in jeder App und für das Einfügen per
  simuliertem ⌘V. Damit könnte die App theoretisch Tastatureingaben mitlesen. Sie tut
  es nicht: Der globale Monitor in `FnKeyMonitor.swift` gibt ausschließlich den
  `keyCode` weiter und speichert nichts.
- **Mikrofon.** Die Aufnahme geht als WAV an den Transkriptions-Endpunkt und wird
  danach gelöscht.
- **Zwischenablage.** Der Text wird kurz hineingelegt, eingefügt, und der vorherige
  Inhalt wird wiederhergestellt. Diktate sind mit
  `org.nspasteboard.ConcealedType` markiert, damit Zwischenablage-Verwalter sie nicht
  archivieren.

Besonders interessant für einen Blick: `TextInserter.swift`, `FnKeyMonitor.swift`,
`LocalServerManager.swift` (startet einen Unterprozess) und `Models.swift`
(Modell-Downloads, per SHA-256 geprüft).

## Was keine Lücke ist

- Im Server-Modus über `http://` ist die Verbindung unverschlüsselt. Das ist bekannt,
  die Einstellungen warnen davor, und es betrifft nur selbst eingetragene Adressen.
- `NSAllowsArbitraryLoads` ist aktiv, weil Nutzer beliebige eigene Server eintragen
  können, auch im VPN. Standard ist `127.0.0.1`.
