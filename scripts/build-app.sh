#!/bin/bash
# Build QuotaSwap.app into build/ and sign it.
# SIGN_ID overrides the signing identity; "-" signs ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ID="${SIGN_ID:-Developer ID Application: Tao Wang (CU3VTR9MRH)}"
if [ "$SIGN_ID" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
    echo "signing identity not found, signing ad hoc: $SIGN_ID" >&2
    SIGN_ID="-"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/QuotaSwap"

APP=build/QuotaSwap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuotaSwap"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp=none -s "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "built $APP (signed: $SIGN_ID)"
