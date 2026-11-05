#!/bin/zsh
# Builds, signs, notarizes and publishes a GitHub release.
#
#   scripts/release.sh            # build + sign + notarize into dist/
#   scripts/release.sh publish    # …and create the GitHub release v$(cat VERSION)
#
# One-time setup:
#   1. Install a "Developer ID Application" certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +).
#      Optional: a "Developer ID Installer" certificate, to ship the Resolve plugin as a .pkg installer.
#   2. Store notarization credentials in the keychain (app-specific password from account.apple.com):
#        xcrun notarytool store-credentials touchrecordkit --apple-id you@example.com --team-id Q8H5WZAY8E
#   3. brew install gh && gh auth login     (only for `publish`)
#
# Overrides: SIGN_ID, INSTALLER_ID, NOTARY_PROFILE (default "touchrecordkit").
set -e
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
NOTARY_PROFILE=${NOTARY_PROFILE:-touchrecordkit}

pick_identity() { security find-identity -v -p "$1" | grep -o "\"$2: [^\"]*\"" | head -1 | tr -d '"'; }
SIGN_ID=${SIGN_ID:-$(pick_identity codesigning "Developer ID Application")}
INSTALLER_ID=${INSTALLER_ID:-$(pick_identity basic "Developer ID Installer")}
[[ -n "$SIGN_ID" ]] || { echo "No 'Developer ID Application' certificate found. See setup notes at the top of this script."; exit 1; }
echo "Signing as: $SIGN_ID"
export SIGN_ID

notarize() { xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait; }

rm -rf dist && mkdir -p dist

# --- Mac app -> notarized, stapled DMG ---------------------------------------
App/build.sh
STAGE=$(mktemp -d)
cp -R App/build/TouchRecordKit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG=dist/TouchRecordKit-$VERSION.dmg
hdiutil create -volname "TouchRecordKit $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$SIGN_ID" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# --- Resolve plugin -> notarized .pkg (or .zip without an installer cert) ----
ofx/build.sh
if [[ -n "$INSTALLER_ID" ]]; then
  ROOT=$(mktemp -d)
  mkdir -p "$ROOT/Library/OFX/Plugins"
  cp -R ofx/build/TouchRecordKit.ofx.bundle "$ROOT/Library/OFX/Plugins/"
  PKG=dist/TouchRecordKit-Resolve-Plugin-$VERSION.pkg
  pkgbuild --root "$ROOT" --identifier com.fform.touchrecordkit.ofx --version "$VERSION" \
    --install-location / --sign "$INSTALLER_ID" --timestamp "$PKG"
  rm -rf "$ROOT"
  notarize "$PKG"
  xcrun stapler staple "$PKG"
else
  echo "No 'Developer ID Installer' certificate: shipping the plugin as a zip."
  ZIP=dist/TouchRecordKit-Resolve-Plugin-$VERSION.zip
  ditto -c -k --keepParent ofx/build/TouchRecordKit.ofx.bundle "$ZIP"
  notarize "$ZIP"
fi

echo; ls -lh dist

if [[ "$1" == "publish" ]]; then
  command -v gh >/dev/null || { echo "Install the GitHub CLI: brew install gh"; exit 1; }
  git diff --quiet && git diff --cached --quiet || { echo "Commit your changes first."; exit 1; }
  git tag -a "v$VERSION" -m "TouchRecordKit $VERSION" 2>/dev/null || true
  git push origin "v$VERSION"
  gh release create "v$VERSION" dist/* --title "TouchRecordKit $VERSION" --generate-notes
fi
