#!/bin/bash
# Erzeugt einmalig ein selbstsigniertes Codesigning-Zertifikat "Orbly Dev"
# im Login-Schlüsselbund. Damit behält die App über Neubauten hinweg dieselbe
# Identität - und macOS verwirft die Bedienungshilfen-Berechtigung NICHT mehr
# bei jedem Build (das passiert bei Ad-hoc-Signierung, weil sich der Code-Hash
# jedes Mal ändert).
#
# Einmal ausführen, danach signiert scripts/build-app.sh automatisch damit.
set -euo pipefail

NAME="Orbly Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Zertifikat '$NAME' existiert bereits - nichts zu tun."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

echo "==> Erzeuge Schlüssel + Zertifikat (gültig 10 Jahre)"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:orbly -out "$TMP/identity.p12"

echo "==> Importiere in den Login-Schlüsselbund"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P orbly -T /usr/bin/codesign

echo "==> Markiere Zertifikat als vertrauenswürdig für Codesigning"
echo "    (macOS fragt jetzt einmal nach deinem Passwort)"
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" \
  || security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "==> Erlaube codesign den Schlüsselzugriff ohne Dialog"
echo "    (fragt nach dem Passwort deines Login-Schlüsselbunds = Anmelde-Passwort)"
security set-key-partition-list -S "apple-tool:,apple:" -s -l "$NAME" "$KEYCHAIN" >/dev/null \
  || echo "    Übersprungen - dann fragt macOS beim ersten Signieren einmal per Dialog ('Immer erlauben' wählen)."

echo ""
echo "Fertig. Ab jetzt signiert scripts/build-app.sh stabil mit '$NAME'."
echo "Nach dem NÄCHSTEN Build einmalig: Systemeinstellungen → Datenschutz & Sicherheit"
echo "→ Bedienungshilfen → Orbly entfernen (-) und neu hinzufügen (+)."
echo "Danach übersteht die Berechtigung alle weiteren Builds."
