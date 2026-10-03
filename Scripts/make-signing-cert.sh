#!/bin/bash
# Creates a self-signed code-signing certificate for WindowQueue in a keychain of its own.
#
# Ad-hoc signatures (`codesign -s -`) change identity on every build, so macOS revokes the
# Accessibility permission each time. Signing with a stable certificate keeps that grant alive,
# for you and, with the release certificate, for everyone updating to a new release.
#
# The keychain's password is random and kept in the login keychain, so scripts can unlock it and
# codesign can use the key without asking. Back up both to keep signing releases on another Mac:
#   ~/Library/Keychains/windowqueue-signing.keychain-db
#   security find-generic-password -s windowqueue-signing -w
set -euo pipefail

NAME="${1:-WindowQueue Release}"
KEYCHAIN="$HOME/Library/Keychains/windowqueue-signing.keychain-db"
SERVICE=windowqueue-signing

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "identity \"$NAME\" already exists"
    exit 0
fi

if [ ! -f "$KEYCHAIN" ]; then
    PASSWORD=$(openssl rand -hex 24)
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN" # no auto-lock timeout
    security add-generic-password -U -a "$USER" -s "$SERVICE" -w "$PASSWORD" -T /usr/bin/security
    # Searched alongside the existing keychains, so codesign finds the identity by name.
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"
fi
PASSWORD=$(security find-generic-password -s "$SERVICE" -w)
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# Security.framework only reads the legacy PKCS#12 algorithms, not OpenSSL 3's defaults. macOS's
# own openssl is LibreSSL, which uses them anyway and has no -legacy flag.
LEGACY=-legacy
openssl version | grep -q LibreSSL && LEGACY=
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -name "$NAME" -out "$TMP/identity.p12" -passout pass:transfer >/dev/null 2>&1

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P transfer -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a password prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

echo "created code-signing identity \"$NAME\" in $KEYCHAIN"
