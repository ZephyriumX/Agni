# Android setup (Windows, macOS or Linux)

## 1. Install
| Need | Command / link |
|---|---|
| Flutter ≥ 3.22 | https://docs.flutter.dev/get-started/install, add `flutter\bin` to PATH |
| Android Studio | https://developer.android.com/studio → *More Actions → SDK Manager*: install **Android SDK Platform 34**, **Platform-Tools**, **Command-line Tools** |
| JDK 17 | bundled with Android Studio (Flutter uses it automatically) |
| Python 3.10+ | for the backend |

```bash
flutter doctor                     # fix every red item for "Android toolchain"
flutter doctor --android-licenses  # accept all
```
## 2. Phone
1. *Settings → About phone →* tap **Build number** 7 times → *Developer options* → enable **USB debugging**.
2. Plug in the cable, accept the "Allow USB debugging" prompt, then `adb devices` must list the phone as `device`.

## 3. Backend
See README §1. For a phone on USB use **`adb reverse`** so the phone's `127.0.0.1:8000` is your PC:
```bash
adb reverse tcp:8000 tcp:8000
```
(Never use `10.0.2.2` on a real phone: it only exists inside the emulator.) Wi-Fi alternative: run the server with
`--host 0.0.0.0`, allow TCP 8000 in the firewall (Private network only; `scripts/windows_firewall.ps1` on Windows) and
set *Server* (welcome screen, or Profile → Server & camera) to `http://<PC-IP>:8000`.
**To use the app without the cable or shared Wi-Fi, deploy the server: `docs/REMOTE_ACCESS.md`.**

## 4. App
```bash
cd app
flutter create --platforms=android --org com.agnipulse --project-name agni_pulse .   # first time only; keeps lib/ and pubspec.yaml
```
Then edit what `flutter create` generated:
* `android/app/build.gradle(.kts)`: `minSdk = 24`.
* Optional: app name in `android/app/src/main/AndroidManifest.xml` → `android:label="Agni-Pulse"`.
* Nothing else: the plugin's manifest adds CAMERA **and INTERNET** (release builds need INTERNET; Flutter only adds it
  to debug builds), and the manifest merger copies both into the app.
* If Gradle complains about Kotlin/AGP versions, align `ext.kotlin_version` and the AGP classpath in
  `packages/ppg_camera/android/build.gradle` with your project's.
```bash
flutter pub get
dart format lib test packages
flutter analyze
flutter test
flutter run                      # debug on the phone
flutter build apk --debug        # build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release --dart-define=API_BASE_URL=https://<your-api>.onrender.com
```
The release APK (`build/app/outputs/flutter-apk/app-release.apk`) can be copied to any phone and installed without a
cable. It is signed with Flutter's debug key unless you configure your own; fine for a demo, not for the Play Store.
For cloud hosting and wireless use see **`docs/REMOTE_ACCESS.md`**.
Kotlin selection tests (no phone needed): `cd android && ./gradlew :ppg_camera:testDebugUnitTest`.

## 5. First scan
Create an account (or sign in), finish the short onboarding (profile, goals, Prakriti), then Home → **Baseline scan** →
grant camera permission. Check the **Camera** card: it shows the camera in use and its frame rate.
If the phone has several back cameras, tap **Change** to try another. Cover the camera **and** the flash with a fingertip.

## 6. Troubleshooting
| Symptom | Meaning / fix |
|---|---|
| "None of this phone's back camera option(s) can give apps at least 55 fps" | Android reports ≤ 30 fps to apps for every back camera. Tap *Copy diagnostics* and read `docs/CAMERA_SELECTION.md`. The scan is never run at a lower rate. |
| Camera card shows a different camera than you want | *Change* → choose it. Unusable cameras are greyed with the reason. |
| `CAMERA_IN_USE` | Another app holds the camera. Close it and Retry. |
| Capture status FAIL, "frame rate fluctuates / dropped frames" | Close background apps, let the phone cool, keep the finger still. |
| "Connection timed out" | Wrong server address for your setup (see §3). *Server* → *Save & test connection*. |
| "Waking up the server…" for ~a minute | Free cloud server was asleep. Normal; it stays awake while in use. |
| Sent back to the sign-in screen | The session ended (signed out elsewhere, password changed, or account recovered). Sign in again; data is kept. |
