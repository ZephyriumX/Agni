# Agni-Pulse Flutter app (Android)

Source only. The app depends on the local plugin `packages/ppg_camera` (Kotlin Camera2).

```bash
cd app
flutter create --project-name agni_pulse --org com.agnipulse --platforms android .   # keeps lib/ and pubspec.yaml
flutter pub get
flutter run --release        # on a real phone (USB debugging)
```
Settings after `flutter create`:
* `android/app/build.gradle(.kts)`: `minSdk = 24`.
* The plugin's manifest already declares the CAMERA permission (merged automatically). INTERNET is in the debug
  manifest; for a **release** build add `<uses-permission android:name="android.permission.INTERNET"/>` to
  `android/app/src/main/AndroidManifest.xml`.
* If Gradle complains about the plugin's Kotlin/AGP versions, align `ext.kotlin_version` / the AGP classpath in
  `packages/ppg_camera/android/build.gradle` with your project's.

Connect to the backend: see the repository README §3 (USB `adb reverse` is the default for real phones).

## What it does
Home (server status, pending uploads) → Scan (permission, Camera2 60 fps capability check, finger detection, live
PPG/APG, pressure coaching, 35 s recording with sensor timestamps, upload, result with comparison/dials) → Vajrasana
timer + before/after graph → Report / Food diary / Prakriti quiz → Settings (URL + layered diagnostics).
A scan that cannot be uploaded is saved on the phone and retried (idempotent).

## Debugging capture on your phone
Scan screen → *Capture diagnostics*: live fps (from sensor timestamps), R/G/B, saturation, exposure time, ISO, frame
duration and the Camera2 capability dump. If you still see < 60 fps, send those lines - they show whether the sensor,
the stream configuration or exposure is the limit.
