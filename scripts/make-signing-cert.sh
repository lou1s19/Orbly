#!/bin/bash
# Creates a self-signed code signing certificate "Orbly Dev" in the login
# keychain, once. With it the app keeps the same identity across rebuilds, and
# macOS stops dropping the accessibility permission on every build (which is
# what happens with ad-hoc signing, because the code hash changes each time).
#
# Run it once, after that scripts/build-app.sh signs with it automatically.
set -euo pipefail

NAME="Orbly Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Certificate '$NAME' already exists, nothing to do."
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

echo "==> Creating key and certificate (valid for 10 years)"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:orbly -out "$TMP/identity.p12"

echo "==> Importing into the login keychain"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P orbly -T /usr/bin/codesign

echo "==> Marking the certificate as trusted for code signing"
echo "    (macOS asks for your password once now)"
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" \
  || security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "==> Allowing codesign to use the key without a dialog"
echo "    (asks for your login keychain password, which is your account password)"
security set-key-partition-list -S "apple-tool:,apple:" -s -l "$NAME" "$KEYCHAIN" >/dev/null \
  || echo "    Skipped. macOS will ask once with a dialog on the first signing, choose 'Always Allow'."

echo ""
echo "Done. From now on scripts/build-app.sh signs stably with '$NAME'."
echo "After the NEXT build, once: System Settings > Privacy & Security"
echo "> Accessibility > remove Orbly (-) and add it again (+)."
echo "After that the permission survives all further builds."
