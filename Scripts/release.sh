#!/bin/bash
# Builds a release of WindowQueue into dist/: a universal (Apple silicon + Intel) app, signed with
# the hardened runtime, packed as a DMG and a zip.
#
# Releases are signed with the self-signed "WindowQueue Release" certificate (create it once with
# `make cert`). It is not notarized, so Gatekeeper asks on first launch — but every release carries
# the same signing identity, so macOS keeps the Accessibility grant across updates. Losing the
# certificate means users have to grant it again once; back it up (see make-signing-cert.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=WindowQueue
BUNDLE_ID=com.mpochec.windowqueue
SIGN_ID=${SIGN_ID:-WindowQueue Release}
KEYCHAIN="$HOME/Library/Keychains/windowqueue-signing.keychain-db"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DIST=dist
STAGE=$DIST/stage
NAME=$APP-$VERSION

if ! security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    echo "No \"$SIGN_ID\" signing identity. Create it with: make cert"
    exit 1
fi
if [ -f "$KEYCHAIN" ]; then
    security unlock-keychain -p "$(security find-generic-password -s windowqueue-signing -w)" "$KEYCHAIN"
fi

LOG=$(mktemp -t windowqueue-release)
quietly() { "$@" >"$LOG" 2>&1 || { tail -40 "$LOG"; echo "failed: $*"; exit 1; }; }

echo "==> Testing"
quietly swift test

echo "==> Building $NAME (arm64 + x86_64)"
quietly swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP

rm -rf "$DIST"
mkdir -p "$STAGE/$APP.app/Contents/MacOS" "$STAGE/$APP.app/Contents/Resources"
cp "$BIN" "$STAGE/$APP.app/Contents/MacOS/$APP"
cp Resources/Info.plist "$STAGE/$APP.app/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/$APP.app/Contents/Resources/AppIcon.icns"
cp LICENSE "$STAGE/$APP.app/Contents/Resources/LICENSE"
printf 'APPL????' > "$STAGE/$APP.app/Contents/PkgInfo"

echo "==> Signing with \"$SIGN_ID\""
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$STAGE/$APP.app"
codesign --verify --strict "$STAGE/$APP.app"

echo "==> Packing"
ditto -c -k --keepParent "$STAGE/$APP.app" "$DIST/$NAME.zip"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DIST/$NAME.dmg"
rm -rf "$STAGE"

echo "==> Done"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip")
