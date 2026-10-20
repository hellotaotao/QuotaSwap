#!/bin/bash
# Build a universal QuotaSwap.app into build/ and sign it.
#   SIGN_ID    signing identity; "-" signs ad hoc
#   VERSION    CFBundleShortVersionString (default: the one in Resources/Info.plist)
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
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

TS=--timestamp=none
[ "${TIMESTAMP:-0}" = 1 ] && TS=--timestamp
codesign --force --options runtime "$TS" -s "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/QuotaSwap"); signed: $SIGN_ID)"
