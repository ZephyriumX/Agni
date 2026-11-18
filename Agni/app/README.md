# Agni-Pulse Flutter app

Source only. Depends on the local plugin `packages/ppg_camera` (Android Camera2 in Kotlin, iOS AVFoundation in Swift).

* Android: `../docs/ANDROID_SETUP.md`
* iOS (needs a Mac): `../docs/IOS_SETUP.md`, then `./tools/setup_ios.sh`
* Camera choice and fps evidence: `../docs/CAMERA_SELECTION.md`
* Timing rules: `../docs/CAPTURE_VALIDATION.md`
* What is verified and what is not: `../docs/STATUS.md`

```bash
flutter create --platforms=android --org com.agnipulse --project-name agni_pulse .   # first time (Android)
flutter pub get && dart format lib test packages && flutter analyze && flutter test
flutter run
```

## Screens
Home dashboard (server status, last scan, scan journey, pending uploads) · Scan (camera card with selector, guided steps,
finger detection, live PPG/APG, 35 s recording with sensor timestamps, on-device timing verdict, upload, result with
comparison) · Vajrasana timer + before/after · Report · Food diary · Prakriti quiz · Setup (server, camera, capture rules).
A scan that cannot be uploaded is saved on the phone and retried (idempotent).
