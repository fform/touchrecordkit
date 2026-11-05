#!/bin/zsh
# Builds the TouchRecordKit Mac app.
#   ./build.sh            -> build/TouchRecordKit.app (ad-hoc signed)
#   ./build.sh install    -> also copy to /Applications
# Set SIGN_ID to a "Developer ID Application: …" identity to sign for distribution
# (hardened runtime + timestamp, ready for notarization). scripts/release.sh does this for you.
set -e
cd "$(dirname "$0")"
VERSION=$(cat ../VERSION)
BUILD=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
APP=build/TouchRecordKit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Info.plist > "$APP/Contents/Info.plist"

# Icon Composer icon -> Assets.car (Liquid Glass, macOS 26+) + AppIcon.icns (older macOS)
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
  --platform macosx --minimum-deployment-target 14.0 --target-device mac \
  --output-partial-info-plist build/icon-partial.plist >/dev/null

# Universal binary
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -parse-as-library -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "build/TouchRecordKit-$arch"
done
lipo -create build/TouchRecordKit-arm64 build/TouchRecordKit-x86_64 -output "$APP/Contents/MacOS/TouchRecordKit"
rm build/TouchRecordKit-arm64 build/TouchRecordKit-x86_64

if [[ -n "$SIGN_ID" ]]; then
  codesign --force --options runtime --timestamp --entitlements TouchRecordKit.entitlements --sign "$SIGN_ID" "$APP"
else
  codesign --force --entitlements TouchRecordKit.entitlements --sign - "$APP"
fi
echo "Built $APP ($VERSION)"

if [[ "$1" == "install" ]]; then
  osascript -e 'quit app "TouchRecordKit"' 2>/dev/null || true
  rm -rf /Applications/TouchRecordKit.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/TouchRecordKit.app"
fi
