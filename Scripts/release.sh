#!/usr/bin/env bash
# Builds a notarized, Developer ID-signed DMG of Redi and signs it for Sparkle.
#
#   Scripts/release.sh <version> <build-number>
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain (team L3FVX7V5JT).
#   2. Notary credentials stored as a keychain profile:
#        xcrun notarytool store-credentials redi-notary --apple-id <you> --team-id L3FVX7V5JT
#   3. Sparkle EdDSA keys (the private key lives in your keychain):
#        "$SPARKLE_BIN/generate_keys"     # prints the public key
#      Put the public key in the REDI_SPARKLE_PUBLIC_KEY build setting (Redi target).
#      SPARKLE_BIN defaults to the Sparkle tools resolved by Xcode in DerivedData.
#   4. Publish dist/appcast.xml next to the DMG at REDI_APPCAST_URL (see the project).
set -euo pipefail

VERSION=${1:?usage: release.sh <version> <build-number>}
BUILD=${2:?usage: release.sh <version> <build-number>}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ARCHIVE="$DIST/Redi.xcarchive"
EXPORT="$DIST/export"
DMG="$DIST/Redi-$VERSION.dmg"
NOTARY_PROFILE=${NOTARY_PROFILE:-redi-notary}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Archiving $VERSION ($BUILD)"
xcodebuild -project "$ROOT/Redi.xcodeproj" -scheme Redi -configuration Release \
  -archivePath "$ARCHIVE" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive

echo "==> Exporting with Developer ID"
cat > "$DIST/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>L3FVX7V5JT</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$DIST/ExportOptions.plist"

echo "==> Building DMG"
STAGING="$DIST/dmg"
mkdir -p "$STAGING"
cp -R "$EXPORT/Redi.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Redi $VERSION" -srcfolder "$STAGING" -fs HFS+ -format ULFO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "==> Signing for Sparkle"
SPARKLE_BIN=${SPARKLE_BIN:-$(find ~/Library/Developer/Xcode/DerivedData -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -1)}
if [[ -x "$SPARKLE_BIN/sign_update" ]]; then
  "$SPARKLE_BIN/sign_update" "$DMG" | tee "$DIST/sparkle-signature.txt"
  "$SPARKLE_BIN/generate_appcast" "$DIST" || echo "generate_appcast failed; write dist/appcast.xml by hand"
else
  echo "Sparkle tools not found; set SPARKLE_BIN to sign the update."
fi

echo "==> Done: $DMG"
