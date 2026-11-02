#!/usr/bin/env bash
# Builds Redi, signs it with Developer ID, notarizes it, and publishes it as a GitHub release: a DMG
# to download, plus the Sparkle appcast that installed copies read to find updates.
#
#   Scripts/release.sh <version> [--build N] [--notes FILE] [--draft] [--dry-run]
#
#   <version>     The version people see, like 1.0 or 1.2.3. The release is tagged v<version>.
#   --build N     The build number (CFBundleVersion). Sparkle compares it to decide what's newer.
#                 Defaults to the number of commits in HEAD, which only grows while main stays linear.
#   --notes FILE  Markdown release notes for the GitHub release and the update window. Without them,
#                 GitHub writes notes from the commits and the update window links to the releases.
#   --draft       Create the release as a draft, to look over and publish on GitHub. Installed copies
#                 don't see it until it's published: they read the appcast of the latest release.
#   --dry-run     Build, sign, and package, but don't notarize or publish. Allows uncommitted changes.
#
# Output goes to dist/. The build reuses .build/release/ between runs.
#
# One-time setup:
#   1. A "Developer ID Application" certificate for team L3FVX7V5JT in your login keychain.
#   2. Notary credentials saved as a keychain profile (NOTARY_PROFILE, default redi-notary). This asks
#      for an app-specific password, which you create at account.apple.com:
#        xcrun notarytool store-credentials redi-notary --apple-id <your Apple ID> --team-id L3FVX7V5JT
#   3. The Sparkle EdDSA private key in your login keychain, matching the REDI_SPARKLE_PUBLIC_KEY build
#      setting. Back it up somewhere safe: without it, installed copies can't take another update.
#        .build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x <backup file>
#      (The tools are there after the first run, or in Xcode's DerivedData for the project.)
#   4. gh, logged in to an account that can create releases in the repository.
set -euo pipefail

TEAM=L3FVX7V5JT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
DERIVED="$ROOT/.build/release"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
NOTARY_PROFILE=${NOTARY_PROFILE:-redi-notary}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }
usage() { echo "usage: Scripts/release.sh <version> [--build N] [--notes FILE] [--draft] [--dry-run]" >&2; exit 64; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

VERSION="" BUILD="" NOTES="" DRAFT=0 DRY_RUN=0
while (($#)); do
  case $1 in
    --build) [[ $# -ge 2 ]] || usage; BUILD=$2; shift 2 ;;
    --notes) [[ $# -ge 2 ]] || usage; NOTES=$2; shift 2 ;;
    --draft) DRAFT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) usage ;;
    *) [[ -z $VERSION ]] || usage; VERSION=$1; shift ;;
  esac
done
[[ -n $VERSION ]] || usage
[[ $VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "the version should look like 1.0 or 1.2.3, not '$VERSION'"
BUILD=${BUILD:-$(git rev-list --count HEAD)}
[[ $BUILD =~ ^[0-9]+$ ]] || die "the build number should be a whole number, not '$BUILD'"
if [[ -n $NOTES ]]; then
  [[ -f $NOTES ]] || die "there's no release notes file at $NOTES"
  NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"
fi

TAG="v$VERSION"
REMOTE=$(git remote get-url origin)
[[ $REMOTE =~ github\.com[:/]([^/]+/[^/]+)$ ]] || die "origin ($REMOTE) isn't a GitHub repository"
REPO=${BASH_REMATCH[1]%.git}
SHA=$(git rev-parse HEAD)
ARCHIVE="$DIST/Redi.xcarchive"
APP="$DIST/export/Redi.app"
DMG="$DIST/Redi-$VERSION.dmg"
UPDATES="$DIST/updates"   # What generate_appcast reads and writes: the new DMG and the appcast.
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

step "Checking before the build"
IDENTITY=$(security find-identity -v -p codesigning \
  | awk -v team="($TEAM)\"" '/"Developer ID Application: / && index($0, team) { print $2; exit }')
[[ -n $IDENTITY ]] || die "there's no Developer ID Application certificate for team $TEAM in your keychain"
if ((DRY_RUN)); then
  [[ -z $(git status --porcelain) ]] || echo "Uncommitted changes are included in this dry run."
else
  command -v gh >/dev/null || die "gh isn't installed (brew install gh)"
  gh auth status >/dev/null 2>&1 || die "gh isn't logged in (gh auth login)"
  [[ -z $(git status --porcelain) ]] || die "commit or stash your changes first: the release is built from HEAD"
  gh api "repos/$REPO/commits/$SHA" --silent 2>/dev/null || die "push HEAD ($SHA) to GitHub first"
  if gh api "repos/$REPO/git/ref/tags/$TAG" --silent 2>/dev/null; then die "$TAG already exists in $REPO"; fi
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "there are no notary credentials in the keychain profile $NOTARY_PROFILE (see the setup at the top of this script)"
fi

rm -rf "$DIST"
mkdir -p "$UPDATES"

# generate_appcast adds the new version to the existing appcast, so earlier versions stay listed.
if gh release view --repo "$REPO" --json tagName >/dev/null 2>&1; then
  gh release download --repo "$REPO" --pattern appcast.xml --dir "$UPDATES" \
    || die "couldn't download appcast.xml from the latest release of $REPO"
  LATEST=$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$UPDATES/appcast.xml" | grep -o '[0-9][0-9]*' | sort -n | tail -1)
  if [[ -n $LATEST ]] && ((BUILD <= LATEST)); then
    die "build $BUILD isn't newer than build $LATEST in the published appcast; pass a higher --build"
  fi
elif ((!DRY_RUN)); then
  echo "There's no earlier release in $REPO, so this starts a new appcast."
fi

step "Archiving Redi $VERSION ($BUILD)"
xcodebuild -quiet -project Redi.xcodeproj -scheme Redi -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive

step "Exporting with Developer ID"
cat > "$DIST/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -quiet -exportArchive -archivePath "$ARCHIVE" -exportPath "$DIST/export" \
  -exportOptionsPlist "$DIST/ExportOptions.plist"

step "Checking the app"
codesign --verify --deep --strict "$APP"
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
grep -q "^Authority=Developer ID Application: .*($TEAM)" <<<"$SIGNATURE" || die "the app isn't signed with Developer ID"
grep -q "^TeamIdentifier=$TEAM" <<<"$SIGNATURE" || die "the app isn't signed by team $TEAM"
grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$SIGNATURE" || die "the app doesn't have the hardened runtime"
INFO="$APP/Contents/Info.plist"
[[ $(plist "$INFO" CFBundleShortVersionString) == "$VERSION" ]] || die "the app's version isn't $VERSION"
[[ $(plist "$INFO" CFBundleVersion) == "$BUILD" ]] || die "the app's build number isn't $BUILD"
[[ $(plist "$INFO" SUFeedURL) == "$FEED_URL" ]] || die "the app checks $(plist "$INFO" SUFeedURL) for updates, not $FEED_URL"
APP_KEY=$(plist "$INFO" SUPublicEDKey)
KEYCHAIN_KEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null) || die "there's no Sparkle signing key in your keychain"
[[ -n $APP_KEY && $APP_KEY == "$KEYCHAIN_KEY" ]] \
  || die "the app's SUPublicEDKey ($APP_KEY) doesn't match the Sparkle key in your keychain ($KEYCHAIN_KEY)"
echo "Signed by $(sed -n 's/^Authority=//p' <<<"$SIGNATURE" | head -1); $(lipo -archs "$APP/Contents/MacOS/Redi")"

step "Building the DMG"
mkdir -p "$DIST/dmg"
ditto "$APP" "$DIST/dmg/Redi.app"
ln -s /Applications "$DIST/dmg/Applications"
hdiutil create -quiet -volname "Redi $VERSION" -srcfolder "$DIST/dmg" -fs HFS+ -format ULFO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if ((DRY_RUN)); then
  step "Skipping notarization (dry run)"
else
  step "Notarizing (this usually takes a few minutes)"
  RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
  STATUS=$(plutil -extract status raw - <<<"$RESULT" 2>/dev/null || true)
  if [[ $STATUS != Accepted ]]; then
    ID=$(plutil -extract id raw - <<<"$RESULT" 2>/dev/null || true)
    [[ -z $ID ]] || xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" || true
    die "notarization failed: ${STATUS:-$RESULT}"
  fi
  xcrun stapler staple -q "$DMG"
  xcrun stapler validate -q "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  spctl --assess --type execute -v "$APP"
fi

# Sign after stapling: stapling changes the DMG, and Sparkle's signature covers its exact bytes.
step "Writing the appcast"
cp "$DMG" "$UPDATES/"
NOTES_ARGS=()
if [[ -n $NOTES ]]; then
  cp "$NOTES" "$UPDATES/Redi-$VERSION.md"
  NOTES_ARGS=(--embed-release-notes)
fi
"$SPARKLE_BIN/generate_appcast" ${NOTES_ARGS[@]+"${NOTES_ARGS[@]}"} --maximum-deltas 0 \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --full-release-notes-url "https://github.com/$REPO/releases" --link "https://github.com/$REPO" \
  "$UPDATES"
grep -q "url=\"https://github.com/$REPO/releases/download/$TAG/Redi-$VERSION.dmg\"" "$UPDATES/appcast.xml" \
  || die "the appcast doesn't point at the new DMG"

if ((DRY_RUN)); then
  step "Dry run finished; nothing was notarized or published"
  echo "DMG:     $DMG"
  echo "Appcast: $UPDATES/appcast.xml"
  exit 0
fi

step "Publishing $TAG to $REPO"
RELEASE_ARGS=(release create "$TAG" "$DMG" "$UPDATES/appcast.xml" --repo "$REPO" --target "$SHA" --title "Redi $VERSION")
if [[ -n $NOTES ]]; then RELEASE_ARGS+=(--notes-file "$NOTES"); else RELEASE_ARGS+=(--generate-notes); fi
if ((DRAFT)); then RELEASE_ARGS+=(--draft); fi
gh "${RELEASE_ARGS[@]}"
git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG" || echo "Couldn't fetch the new tag; run git fetch --tags."

step "Done: Redi $VERSION ($BUILD)"
if ((DRAFT)); then
  echo "The release is a draft. Publish it on GitHub; installed copies see the update after that."
fi
