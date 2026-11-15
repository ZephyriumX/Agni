# iOS setup (macOS required)

> **Status: implemented, NOT compiled, NOT simulator-tested, NOT device-tested.** It was written without access to a
> Mac. Treat the first Xcode build as the first real test and expect small fixes. See `docs/STATUS.md`.

## Why macOS is required
Building and signing an iOS app needs Apple's toolchain (Xcode, the iOS SDK, `codesign`, the simulator). Apple only ships
it for macOS, so an iOS binary cannot be built on Windows or Linux.

## 1. Install
```bash
xcode-select --install                         # command-line tools
# Install Xcode from the Mac App Store, then:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept
brew install cocoapods                         # or: sudo gem install cocoapods
# Flutter >= 3.22: https://docs.flutter.dev/get-started/install/macos
flutter doctor                                 # the "Xcode" and "CocoaPods" lines must be green
```
## 2. Apple Developer account
| Goal | Account |
|---|---|
| Run on **your own iPhone** from Xcode / `flutter run`, simulator | **Free** Apple ID ("Personal Team"). Profiles expire after **7 days** (re-run to renew); limited app/device counts. |
| TestFlight, ad-hoc/enterprise distribution, App Store, distribution-signed archive (`.ipa`) | **Paid** Apple Developer Program (US$99 / year). |

## 3. Project setup (once)
```bash
cd app
./tools/setup_ios.sh
```
The script generates `app/ios/` with `flutter create`, adds **only** `NSCameraUsageDescription` (no microphone, no
location), a development-only `NSAllowsLocalNetworking` exception plus a local-network usage text (so the app may reach a
server on your Wi-Fi over `http://`), sets the iOS deployment target to **13.0**, then runs `flutter pub get` and `pod install`.
Production builds should use HTTPS and remove those two local-network entries.

## 4. Signing
```bash
open ios/Runner.xcworkspace
```
Xcode → *Runner* target → **Signing & Capabilities** → tick *Automatically manage signing* → choose your **Team**
→ change **Bundle Identifier** to something unique (e.g. `com.yourname.agnipulse`).

## 5. Run
**Simulator** (no camera: the app starts, then states clearly that no usable back camera exists; this checks UI, not capture):
```bash
open -a Simulator
flutter run -d "iPhone 15"
```
**Physical iPhone** (the only way to test capture):
1. Plug in, unlock, tap *Trust*. iOS 16+: *Settings → Privacy & Security → Developer Mode* → On (phone restarts).
2. Start the backend on the Mac with `--host 0.0.0.0` (README §1) and find its address: `ipconfig getifaddr en0`.
3. Run (the iPhone and the Mac must be on the same Wi-Fi):
```bash
flutter devices
flutter run -d <iphone-id> --dart-define=API_BASE_URL=http://<mac-ip>:8000
```
4. First launch with a free account: *Settings → General → VPN & Device Management →* trust your developer certificate.
5. Allow **Camera** and **Local Network** when asked.

## 6. Archive
```bash
flutter build ios --release --no-codesign        # compile check only
flutter build ipa --release                      # needs distribution signing => paid account
```
or Xcode: *Product → Destination → Any iOS Device (arm64)* → *Product → Archive* → *Distribute App*.

## 7. What to verify on the iPhone (and report back)
* The scan screen lists the iPhone's back cameras (wide / ultra-wide / telephoto) with fps. Telephoto and ultra-wide may
  show "no torch": that is real hardware behaviour, not a bug.
* *Capture diagnostics* shows actual fps and the timing verdict (PASS/WARNING/FAIL). **Do not assume every iPhone gives
  60 fps to apps**: read the number.
* Torch turns on when the scan starts and off when it ends or you leave the screen.

## 8. Troubleshooting
| Symptom | Fix |
|---|---|
| `pod install` fails | `sudo gem install cocoapods` or `brew reinstall cocoapods`, then `cd ios && pod repo update && pod install` |
| "Untrusted Developer" on the phone | Settings → General → VPN & Device Management → trust |
| App cannot reach the server | Use the Mac's Wi-Fi IP, not 127.0.0.1; allow *Local Network*; same Wi-Fi; server started with `--host 0.0.0.0` |
| Camera permission was denied | iPhone Settings → Agni-Pulse → Camera, then Retry |
| Build error in `ios/Classes/*.swift` | Send the exact Xcode error: this code has not been compiled yet |
