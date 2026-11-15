#!/usr/bin/env bash
# One-time iOS project setup for Agni-Pulse. macOS + Xcode only.
#   cd app && ./tools/setup_ios.sh
# What it does (and nothing else):
#   1. generates the ios/ Runner project with `flutter create` (only if app/ios does not exist yet)
#   2. adds NSCameraUsageDescription to Info.plist (the ONLY permission; no microphone, no location)
#   3. adds a development-only App Transport Security exception for LOCAL-network http:// (NSAllowsLocalNetworking)
#      and the local-network usage text iOS shows when the app talks to the server on your Wi-Fi
#   4. sets the iOS deployment target to 13.0 (Podfile + Xcode project)
#   5. flutter pub get + pod install
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname)" == "Darwin" ]] || { echo "ERROR: iOS builds need macOS with Xcode (this is $(uname))."; exit 1; }
command -v flutter >/dev/null   || { echo "ERROR: flutter is not on PATH. See docs/IOS_SETUP.md."; exit 1; }
command -v xcodebuild >/dev/null || { echo "ERROR: Xcode is not installed (xcodebuild missing). See docs/IOS_SETUP.md."; exit 1; }
command -v pod >/dev/null       || { echo "ERROR: CocoaPods missing. Run: brew install cocoapods"; exit 1; }

if [[ ! -d ios ]]; then
  flutter create --platforms=ios --org com.agnipulse --project-name agni_pulse .
fi

PLIST=ios/Runner/Info.plist
PB=/usr/libexec/PlistBuddy
set_str() { "$PB" -c "Set :$1 $2" "$PLIST" 2>/dev/null || "$PB" -c "Add :$1 string $2" "$PLIST"; }

set_str NSCameraUsageDescription "Agni-Pulse uses the camera and flash to read your pulse from your fingertip. Images are processed on the phone and never saved."
set_str NSLocalNetworkUsageDescription "Agni-Pulse connects to your own analysis server on the local network (development)."
"$PB" -c "Add :NSAppTransportSecurity dict" "$PLIST" 2>/dev/null || true
"$PB" -c "Set :NSAppTransportSecurity:NSAllowsLocalNetworking true" "$PLIST" 2>/dev/null \
  || "$PB" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$PLIST"

# deployment target 13.0
if [[ -f ios/Podfile ]]; then
  sed -i '' -E "s/^#? ?platform :ios, '[0-9.]+'/platform :ios, '13.0'/" ios/Podfile
  grep -q "^platform :ios, '13.0'" ios/Podfile || sed -i '' "1i\\
platform :ios, '13.0'
" ios/Podfile
fi
sed -i '' -E 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 13.0;/g' ios/Runner.xcodeproj/project.pbxproj

flutter pub get
(cd ios && pod install)

echo
echo "Done. Next: open ios/Runner.xcworkspace in Xcode, choose your Team under Signing & Capabilities,"
echo "then run:  flutter run -d <your iPhone>     (see docs/IOS_SETUP.md)"
