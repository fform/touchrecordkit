#!/bin/zsh
# Builds the TouchRecordKit OFX plugin for DaVinci Resolve.
#   ./build.sh            -> build/TouchRecordKit.ofx.bundle (ad-hoc signed)
#   ./build.sh install    -> also copy to /Library/OFX/Plugins (asks for your password)
# Set SIGN_ID to a "Developer ID Application: …" identity to sign for distribution.
set -e
cd "$(dirname "$0")"
VERSION=$(cat ../VERSION)
B=build/TouchRecordKit.ofx.bundle
rm -rf "$B"
mkdir -p "$B/Contents/MacOS"
cat > "$B/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TouchRecordKit.ofx</string>
  <key>CFBundleIdentifier</key><string>com.fform.touchrecordkit.ofx</string>
  <key>CFBundleName</key><string>TouchRecordKit</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
</dict></plist>
PLIST
clang++ -std=c++17 -O2 -fobjc-arc -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -fvisibility=hidden -I vendor/openfx \
  src/Plugin.mm src/Overlay.mm src/TouchData.mm \
  -framework Foundation -framework CoreGraphics -framework CoreText \
  -o "$B/Contents/MacOS/TouchRecordKit.ofx"
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$B"
else
  codesign --force --sign - "$B"
fi
echo "Built $B ($VERSION)"

if [[ "$1" == "install" ]]; then
  sudo mkdir -p /Library/OFX/Plugins
  sudo rm -rf /Library/OFX/Plugins/PadRecTouches.ofx.bundle   # pre-rename build
  sudo rm -rf /Library/OFX/Plugins/TouchRecordKit.ofx.bundle
  sudo cp -R "$B" /Library/OFX/Plugins/
  echo "Installed to /Library/OFX/Plugins — restart DaVinci Resolve."
fi
