# Camera selection

## What was wrong
v0.3/0.4-alpha looked only at the cameras the OS lists in `cameraIdList` and reported "camera 0, max 30 fps". Phones with
several rear lenses (your phone has 1x / 2x / 5x) usually list **one combined (logical) camera** and keep the real
lenses behind `physicalCameraIds`. They were never examined, and the choice was made silently.

## What it does now
* **Android:** lists every back camera: the ones in `cameraIdList` **and** each physical lens behind a combined camera
  (API 28+, opened through `OutputConfiguration.setPhysicalCameraId`). Each entry shows the highest YUV frame rate Android
  gives an app for that lens (read from `StreamConfigurationMap`, not guessed), flash, manual-exposure support and a
  35 mm-equivalent focal length used only to label *ultra-wide / main / telephoto*.
* **iOS:** lists the wide, ultra-wide and telephoto devices (virtual dual/triple cameras are not used: they can switch
  lenses mid-scan) with their format-derived frame rates and torch availability.
* **Automatic mode** ranks: reaches the target fps first, then fps up to the target, manual exposure, the lens closest to
  the main one (it sits next to the flash), combined camera before a physical lens.
* **Manual choice:** scan screen → *Camera → Change*. The choice is remembered. If the chosen camera cannot reach the
  minimum fps it is **refused with the reason**, never silently replaced.
* Cameras without a flash/torch are listed but disabled (a pulse cannot be read without light).

## If every camera still says "30 fps"
Then Android itself offers apps no more than 30 fps on this phone. The app now shows the evidence per camera:
`yuvMaxFps` (what apps get), `videoMaxFps` (video-recording class streams), `aeFps`, `highSpeed` ranges, and the number of
hidden physical lenses. A phone's own camera app can record 1080p60 through vendor paths that third-party apps cannot use.
In that case the scan is **not** run at a lower rate (PPG/APG derivatives are not valid at 30 fps) and the app says why.
Use **Copy diagnostics** on the blocked screen and send the text: it shows which path (if any) would be needed.

## Honest status
Implemented, not compiled, not tested on any phone. Selection logic has JVM tests
(`android/src/test/.../CameraChoiceTest.kt`) and the Dart parsing has `app/test/ppg_capabilities_test.dart`; neither has been run.


## High-speed mode (v0.5.0)

If no regular YUV stream reaches the minimum (55 fps), a camera is still usable when it offers a constrained
high-speed range whose **lower** bound is >= the minimum. Preference: lowest upper bound, fixed ranges first
(e.g. [120,120] before [60,120]); a regular YUV stream is preferred when equal. Physical lenses behind a logical
camera are not offered high-speed (no per-lens routing for such sessions).

High-speed sessions cannot feed an ImageReader, so frames go to a SurfaceTexture and a GPU shader averages a 32x32 grid over the
centre 50 % into a float render target (8-bit would erase the pulse; if float rendering is unsupported the scan fails with
`HS_GL_UNSUPPORTED`). Timestamps are the real sensor timestamps; the backend validates and analyses at the true rate (120 fps
is not relabelled or downsampled). Exposure is auto, then AE/AWB-locked during measurement.
Colour values come from the driver's YUV->RGB conversion, so they are not numerically identical to the YUV path.
