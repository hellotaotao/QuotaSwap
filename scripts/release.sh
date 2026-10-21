#!/bin/bash
# Build, notarize and publish a release: scripts/release.sh 0.1.0
#
# One-time setup (asks for an app-specific password from account.apple.com):
#   xcrun notarytool store-credentials notary --apple-id <email> --team-id CU3VTR9MRH
#
# Produces build/QuotaSwap-<version>.dmg, uploads it as GitHub release v<version>,
# and prints the sha256 for the Homebrew cask.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
PROFILE="${NOTARY_PROFILE:-notary}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Tao Wang (CU3VTR9MRH)}"
TAG="v$VERSION"
DMG="build/QuotaSwap-$VERSION.dmg"

[ -z "$(git status --porcelain)" ] || { echo "working tree not clean" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null || {
    echo "notary profile '$PROFILE' missing; see the setup line at the top of this script" >&2; exit 1; }

scripts/test-fake.sh
VERSION="$VERSION" TIMESTAMP=1 SIGN_ID="$SIGN_ID" scripts/build-app.sh

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait | tee build/notary.log
    grep -q "status: Accepted" build/notary.log || { echo "notarization failed for $1" >&2; exit 1; }
}

# The app is notarized and stapled on its own, so a copy dragged out of the
# DMG opens offline too; then the DMG gets the same treatment.
ZIP="build/QuotaSwap-$VERSION.zip"
ditto -c -k --keepParent build/QuotaSwap.app "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple build/QuotaSwap.app

STAGE="$(mktemp -d)"
cp -R build/QuotaSwap.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname QuotaSwap -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp -s "$SIGN_ID" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

# A copy under a fixed name keeps releases/latest/download/QuotaSwap.dmg valid for the website.
cp "$DMG" build/QuotaSwap.dmg
gh release create "$TAG" "$DMG" build/QuotaSwap.dmg --repo hellotaotao/QuotaSwap --title "QuotaSwap $VERSION" \
    --notes "Notarized universal build for macOS 13+. Install with \`brew install --cask hellotaotao/tap/quotaswap\` or open the DMG."
echo "sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
