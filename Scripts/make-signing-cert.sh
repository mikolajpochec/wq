#!/bin/bash
# Creates a self-signed code-signing certificate in the login keychain.
#
# Ad-hoc signatures (`codesign -s -`) change identity on every rebuild, so macOS revokes the
# Accessibility permission each time. Signing with a stable certificate keeps that grant alive.
set -euo pipefail

NAME="${1:-WindowQueue Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "identity \"$NAME\" already exists"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# Security.framework only reads the legacy PKCS#12 algorithms, not OpenSSL 3's defaults.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -name "$NAME" -out "$TMP/identity.p12" -passout pass: >/dev/null 2>&1

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "" -A -T /usr/bin/codesign >/dev/null

echo "created code-signing identity \"$NAME\""
