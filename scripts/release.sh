#!/bin/bash
#
# Builds, signs, notarizes and packages DevCleanerPro for distribution.
#
#   scripts/release.sh 1.0.0            build + notarize + DMG into dist/
#   scripts/release.sh 1.0.0 --install  the same, then install into /Applications
#   scripts/release.sh 1.0.0 --publish  the same, then create the GitHub release
#   scripts/release.sh 1.0.0 --skip-notarize   local smoke test, unnotarized
#
# Signing is automatic: the app archives with the team's development identity and
# `xcodebuild -exportArchive` re-signs it with Developer ID. With
# -allowProvisioningUpdates, Xcode creates the Developer ID certificate on first
# use if the account does not have one yet, so nothing has to be set up by hand
# beyond being signed in to the Apple ID in Xcode.
#
# The rest of the setup is described in docs/RELEASING.md.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
shift || true

INSTALL=0
PUBLISH=0
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --install)        INSTALL=1 ;;
    --publish)        PUBLISH=1 ;;
    --skip-notarize)  NOTARIZE=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "usage: scripts/release.sh <version> [--install] [--publish] [--skip-notarize]" >&2
  echo "       version must look like 1.0 or 1.0.0" >&2
  exit 2
fi

APP_NAME="DevCleanerPro"
TEAM_ID="FPU5BPQ3UD"
NOTARY_PROFILE="devcleanerpro"
BUILD_DIR="build/release"
DIST_DIR="dist"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
note() { printf '\033[33m    %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
step "Preflight"

# Captured into a variable rather than piped: with `set -o pipefail`, `grep -q`
# exits on the first match, the producer takes a SIGPIPE, and the pipeline reports
# failure even though the match succeeded.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
if ! grep -q "Developer ID Application" <<<"$IDENTITIES"; then
  note "no Developer ID Application certificate in the keychain yet —"
  note "the export below will ask Xcode to create one (-allowProvisioningUpdates)."
  note "If that fails, make it by hand: Xcode › Settings › Accounts › $TEAM_ID ›"
  note "Manage Certificates › + › Developer ID Application."
fi

if (( NOTARIZE )) && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  die "no notarytool credentials stored under the profile '$NOTARY_PROFILE'.
      xcrun notarytool store-credentials $NOTARY_PROFILE \\
        --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>
      See docs/RELEASING.md."
fi

if (( PUBLISH )); then
  [[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit before publishing"
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "version $VERSION, build $BUILD_NUMBER, team $TEAM_ID"

# ------------------------------------------------------------------ archive --
step "Archiving"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive \
  | grep -E "error:|warning:|ARCHIVE" || true

[[ -d "$ARCHIVE" ]] || die "no archive at $ARCHIVE"

# ------------------------------------------------------------------- export --
step "Exporting with Developer ID"
OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>            <string>developer-id</string>
  <key>signingStyle</key>      <string>automatic</string>
  <key>teamID</key>            <string>$TEAM_ID</string>
  <key>destination</key>       <string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

[[ -d "$APP" ]] || die "export produced no app bundle at $APP"

# ------------------------------------------------------------------- verify --
step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"

SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -E "^Identifier|^Authority|^TeamIdentifier|flags=" <<<"$SIGNATURE"

grep -q "Developer ID Application" <<<"$SIGNATURE" \
  || die "the exported app is not signed with Developer ID — it would not open elsewhere"
grep -q "flags=.*runtime" <<<"$SIGNATURE" \
  || die "hardened runtime is not enabled — notarization would be rejected"

# ---------------------------------------------------------------------- dmg --
step "Building the disk image"
mkdir -p "$DIST_DIR"
rm -f "$DMG"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$DMG"

echo "$DMG ($(du -h "$DMG" | cut -f1))"

# Signing the disk image itself is a nicety, and only possible when a Developer
# ID private key is in the keychain. Xcode's automatic signing may instead use
# cloud-managed signing, where the key stays with Apple and codesign has nothing
# to sign with. The app inside is signed either way, and the notarization ticket
# staples to the image either way, so an unsigned image costs nothing but the
# ability to run `spctl` against the image.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
DEV_ID="$(awk '/Developer ID Application/ { print $2; exit }' <<<"$IDENTITIES")"
DMG_SIGNED=0
if [[ -n "$DEV_ID" ]]; then
  step "Signing the disk image"
  codesign --sign "$DEV_ID" --timestamp --force "$DMG"
  codesign --verify --verbose=2 "$DMG"
  DMG_SIGNED=1
else
  note "no Developer ID private key in the keychain (cloud-managed signing) —"
  note "the disk image stays unsigned. The app inside is signed and the ticket"
  note "is stapled to the image, so this changes nothing for whoever installs it."
fi

# -------------------------------------------------------------- notarization --
if (( NOTARIZE )); then
  step "Notarizing (this takes a few minutes)"
  xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  step "Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  # Gatekeeper's verdict on the thing that matters: will the app be allowed to
  # run on someone else's Mac. Assessed against the app rather than the image,
  # because an unsigned image has no signature to assess.
  step "Gatekeeper"
  spctl --assess --type exec --verbose=2 "$APP"
  if (( DMG_SIGNED )); then
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  fi
else
  echo
  note "--skip-notarize: this build will be refused by Gatekeeper on another Mac."
fi

# ------------------------------------------------------------------ checksum --
step "Checksum"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$SHA  $(basename "$DMG")" | tee "$DMG.sha256"

# ------------------------------------------------------------------- install --
if (( INSTALL )); then
  step "Installing into /Applications"
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "quitting the running instance"
    osascript -e "tell application \"$APP_NAME\" to quit" || true
    for _ in 1 2 3 4 5; do pgrep -x "$APP_NAME" >/dev/null || break; /bin/sleep 1; done
  fi
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  echo "/Applications/$APP_NAME.app"
fi

# ------------------------------------------------------------------- publish --
if (( PUBLISH )); then
  step "Publishing the GitHub release"
  TAG="v$VERSION"
  git tag -a "$TAG" -m "$APP_NAME $VERSION" 2>/dev/null || echo "tag $TAG already exists"
  git push origin "$TAG"

  NOTES="$BUILD_DIR/release-notes.md"
  scripts/release-notes.sh "$VERSION" > "$NOTES"

  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh release create "$TAG" "$DMG" "$DMG.sha256" \
      --title "$APP_NAME $VERSION" \
      --notes-file "$NOTES"
  else
    note "gh is not installed or not authenticated — the tag is pushed, the release is not."
    note "Create it by hand at https://github.com/vvodicka/dev-cleaner-pro/releases/new?tag=$TAG"
    note "and attach:"
    note "  $DMG"
    note "  $DMG.sha256"
    note "Release notes were written to $NOTES."
  fi

  echo
  echo "Then update the Homebrew cask:"
  echo "  scripts/update-cask.sh $VERSION"
fi

step "Done"
echo "artifact: $DMG"
echo "sha256:   $SHA"
