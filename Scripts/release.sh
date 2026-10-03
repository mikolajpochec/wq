#!/bin/bash
# Builds a release of WindowQueue into dist/: a universal (Apple silicon + Intel) app, signed with
# the hardened runtime, packed as a DMG and a zip.
#
# Signing: a "Developer ID Application" certificate in the keychain is used when there is one
# (override with SIGN_ID=...). The app is then notarized and stapled if a notarytool keychain
# profile named $NOTARY_PROFILE (default: windowqueue) exists — create it once with
#   xcrun notarytool store-credentials windowqueue --apple-id <id> --team-id <team>
# Without a Developer ID the app is signed ad hoc: it runs, but Gatekeeper asks on first launch
# and macOS forgets the Accessibility grant with every new build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=WindowQueue
BUNDLE_ID=com.mpochec.windowqueue
NOTARY_PROFILE=${NOTARY_PROFILE:-windowqueue}
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DIST=dist
STAGE=$DIST/stage
NAME=$APP-$VERSION

SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -oE '"Developer ID Application: [^"]+"' | tr -d '"' || true)}
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=-
    echo "No Developer ID certificate: signing ad hoc, without notarization."
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

echo "==> Signing with: $SIGN_ID"
TIMESTAMP=--timestamp
[ "$SIGN_ID" = "-" ] && TIMESTAMP=--timestamp=none
codesign --force --options runtime $TIMESTAMP --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$STAGE/$APP.app"
codesign --verify --strict --verbose=1 "$STAGE/$APP.app"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}
CAN_NOTARIZE=false
if [ "$SIGN_ID" != "-" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    CAN_NOTARIZE=true
elif [ "$SIGN_ID" != "-" ]; then
    echo "No notarytool profile '$NOTARY_PROFILE': skipping notarization."
fi

if $CAN_NOTARIZE; then
    echo "==> Notarizing the app"
    ditto -c -k --keepParent "$STAGE/$APP.app" "$DIST/notarize.zip"
    notarize "$DIST/notarize.zip"
    rm "$DIST/notarize.zip"
    xcrun stapler staple "$STAGE/$APP.app"
fi

echo "==> Packing"
ditto -c -k --keepParent "$STAGE/$APP.app" "$DIST/$NAME.zip"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DIST/$NAME.dmg"
if [ "$SIGN_ID" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DIST/$NAME.dmg"
fi
if $CAN_NOTARIZE; then
    echo "==> Notarizing the disk image"
    notarize "$DIST/$NAME.dmg"
    xcrun stapler staple "$DIST/$NAME.dmg"
fi
rm -rf "$STAGE"

echo "==> Done"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip")
