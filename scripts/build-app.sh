#!/bin/bash
# Build a universal QuotaSwap.app into build/ and sign it.
#   SIGN_ID    signing identity; "-" signs ad hoc
#   VERSION    CFBundleShortVersionString (default: `git describe --tags` without the v,
#              e.g. 0.2.1-2-gdefa701 for two commits past v0.2.1, -dirty with local changes)
#   TIMESTAMP  set to 1 for a secure timestamp, required for notarization
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ID="${SIGN_ID:-Developer ID Application: Tao Wang (CU3VTR9MRH)}"
if [ "$SIGN_ID" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
    echo "signing identity not found, signing ad hoc: $SIGN_ID" >&2
    SIGN_ID="-"
fi

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/QuotaSwap"

APP=build/QuotaSwap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuotaSwap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rsync -a --exclude tests --exclude tsconfig.json --exclude .claude-plugin/types Resources/ClaudeMods "$APP/Contents/Resources/"
VERSION="${VERSION:-$(git describe --tags --always --dirty | sed 's/^v//')}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

TS=--timestamp=none
[ "${TIMESTAMP:-0}" = 1 ] && TS=--timestamp
codesign --force --options runtime "$TS" -s "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/QuotaSwap"); signed: $SIGN_ID)"
