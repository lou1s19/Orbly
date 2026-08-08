# Ein Release veröffentlichen

Orbly aktualisiert sich über [Sparkle](https://sparkle-project.org). Der Update-Feed und
die Downloads liegen bei der Website (`orbly-website`, deployt auf Vercel), nicht auf
GitHub: Sparkle muss die `appcast.xml` ohne Login abrufen können, und Download und Update
sollen von derselben Adresse kommen.

## Der Ablauf

```bash
# 1. Bauen, signieren, notarisieren, Zip + DMG + appcast erzeugen.
#    Die Identität MUSS mitgegeben werden, sonst entsteht ein Test-Build,
#    den publish-release.sh zu Recht ablehnt.
ORBLY_SIGN_IDENTITY="Developer ID Application: Louis Saks (H8XJ9NV6ZQ)" \
  bash scripts/release.sh 1.1.0

# 2. Veröffentlichen: Zip, DMG und appcast ins Website-Repo, committen, pushen.
#    Vercel deployt automatisch. Website-Repo standardmäßig ~/Desktop/orbly-website,
#    anderer Ort über ORBLY_SITE_REPO.
bash scripts/publish-release.sh 1.1.0 "Was ist neu: …"

# 3. Angezeigte Versionsnummer der Website nachziehen:
#    src/lib/site.ts -> downloads.mac.version

# 4. Versions-Bump hier committen und taggen (Rollback-Punkt):
git add -A && git commit -m "release: v1.1.0" && git tag v1.1.0 && git push --tags origin main
```

## Was dabei schiefgehen kann

- **Schritt 4 nicht überspringen.** Sparkle vergleicht nur `CFBundleVersion`. Bleibt der
  Bump liegen, hat das nächste Release dieselbe Build-Nummer und niemand sieht das
  Update. `release.sh` prüft das gegen den Live-Feed und bricht sonst ab.
- **Der private Sparkle-Schlüssel ist unersetzlich.** Er liegt nur im Schlüsselbund
  („Private key for signing Sparkle updates"), der öffentliche steht als `SUPublicEDKey`
  in `Resources/Info.plist`. Ohne den privaten Schlüssel bekommt keine installierte Orbly
  je wieder ein Update. Einmal exportieren und **außerhalb** des Repos sichern:
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <pfad außerhalb des repos>`
- **Die Feed-Adresse steckt in jeder ausgelieferten App** und muss erreichbar bleiben.
  Bei einem Umzug auf eine eigene Domain die alte Adresse weiter bedienen oder dauerhaft
  weiterleiten, bis alle Installationen ein Update mit neuer `SUFeedURL` haben.
- **Nur genau ein Zertifikat „Developer ID Application" im Schlüsselbund.** Bei zwei
  gleichnamigen bricht `codesign` beim DMG mit „ambiguous" ab. `build-app.sh` prüft das.
- **Reihenfolge:** erst Dateien hochladen, dann die appcast. `publish-release.sh` macht
  beides in einem Commit und prüft vorher, dass die appcast auf eine vorhandene Datei zeigt.
- **Das Update-Zip ist der einzige Kanal zu bestehenden Installationen.** Ist die App
  darin falsch signiert oder nicht notarisiert, lehnt Sparkle das Update dauerhaft ab und
  es gibt keinen Weg, das zu reparieren. Darum prüft `publish-release.sh` Signatur,
  Notarisierung, Stapel und Universal-Binary und bricht sonst ab.

## Einmalige Einrichtung

- Developer-ID-Zertifikat im Schlüsselbund (Team `H8XJ9NV6ZQ`). Ohne Developer ID und
  Notarisierung blockt Gatekeeper die App auf fremden Macs.
- notarytool-Profil namens `Orbly`:
  `xcrun notarytool store-credentials Orbly --team-id H8XJ9NV6ZQ …`
  (Achtung: Die Team-ID ist nicht die Zertifikats-ID des „Apple Development"-Zertifikats.
  Mit der falschen antwortet notarytool `401 Invalid credentials`. Zum Konto, dem das Team
  gehört, siehe interne Notizen, nicht dieses Repo.)
- Whisper-Engine: `brew install cmake && bash scripts/build-whisper-engine.sh`.
  Ohne `vendor/whisper-server` bricht ein Release-Build ab, weil die App ohne
  mitgelieferte Engine für alle ohne Homebrew unbenutzbar wäre.

## Vor dem Veröffentlichen selbst nachsehen

```bash
APP="$HOME/Library/Caches/Orbly/build/Orbly.app"
codesign --verify --deep --strict --verbose=2 "$APP"    # Signatur vollständig?
codesign -dv --verbose=4 "$APP" 2>&1 | grep Authority   # Developer ID, nicht Dev-Zertifikat?
spctl -a -t exec -vv "$APP"                             # würde Gatekeeper starten?
```

Den Update-Weg wirklich testen: in einem frischen Benutzerkonto oder auf einem zweiten Mac
eine ältere Version installieren und „Nach Updates suchen …" klicken. Nur so zeigt sich,
ob Signatur und Build-Nummer für Sparkle stimmen.
