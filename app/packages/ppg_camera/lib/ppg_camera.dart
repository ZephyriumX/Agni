import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// One selectable back camera (a camera listed by the OS, or one physical lens behind a logical camera).
class PpgCameraInfo {
  /// Stable key within a device: "0" or "0:2" (logical:physical). Pass to [PpgCamera.start].
  final String key;
  final String label;
  final String kind; // single | logical | physical
  final bool hasFlash, manualSensor, meetsMinimum, meetsTarget;

  /// Highest YUV stream rate Android will give an app for this camera (what the analysis can use).
  final double maxFps;

  /// Diagnostic only: video-class (SurfaceTexture) max rate. If this is higher than [maxFps] the phone's
  /// own camera app may record faster than third-party apps can read frames.
  final double surfaceMaxFps;
  final double? equivMm;

  /// How this camera reaches the minimum rate: 'yuv' (regular stream), 'highspeed' (constrained high-speed
  /// session read on the GPU) or null (cannot).
  final String? mode;

  /// Frame rate the analysis will really get with [mode] (null if unusable).
  final double? usableFps;
  final String reason; // 'ok' or why it cannot be used
  final Map<String, dynamic> raw;

  PpgCameraInfo._(this.key, this.label, this.kind, this.hasFlash, this.manualSensor, this.meetsMinimum,
      this.meetsTarget, this.maxFps, this.surfaceMaxFps, this.equivMm, this.mode, this.usableFps, this.reason, this.raw);

  factory PpgCameraInfo.fromMap(Map m) {
    final key = (m['key'] ?? m['id']).toString();
    return PpgCameraInfo._(
      key,
      (m['label'] as String?) ?? 'Camera $key',
      (m['kind'] as String?) ?? 'single',
      m['hasFlash'] == true,
      m['manualSensor'] == true,
      m['meetsMinimum'] == true,
      m['meetsTarget'] == true,
      ((m['maxYuvFps'] ?? m['maxFps'] ?? 0) as num).toDouble(),
      ((m['surfaceMaxFps'] ?? 0) as num).toDouble(),
      (m['equivMm'] as num?)?.toDouble(),
      m['mode'] as String?,
      (m['usableFps'] as num?)?.toDouble(),
      (m['reason'] as String?) ?? 'ok',
      Map<String, dynamic>.from(m),
    );
  }

  bool get usable => meetsMinimum;
  bool get highSpeed => mode == 'highspeed';

  /// "60 fps" / "120 fps (high-speed mode)" for the UI.
  String get speedLabel => usableFps == null
      ? 'max ${maxFps.toStringAsFixed(0)} fps'
      : '${usableFps!.toStringAsFixed(0)} fps${highSpeed ? ' (high-speed mode)' : ''}';
}

/// Capabilities as reported by the platform camera API (not guesses).
class PpgCapabilities {
  /// Legacy flag: a stream that advertises >= 60 fps exists.
  final bool supports60;

  /// The chosen camera reaches the requested MINIMUM fps (the hard minimum, e.g. 55). Hardware pre-check
  /// only; the real verdict comes from the recorded sensor timestamps.
  final bool meetsMinimum;

  /// The chosen camera reaches the requested TARGET fps.
  final bool meetsTarget;

  /// At least one camera reaches the minimum (independent of the user's selection).
  final bool anyMeetsMinimum;

  /// 'android' (Camera2) or 'ios' (AVFoundation).
  final String platform;
  final Map<String, dynamic>? chosen;
  final List<PpgCameraInfo> cameras;

  /// Key the automatic mode would pick (null if no camera is usable).
  final String? autoKey;

  /// Physical lenses the OS lists but refuses to describe to apps (e.g. "0:2"). Diagnostic.
  final List<String> hiddenPhysicalIds;
  final Map<String, dynamic> raw;

  PpgCapabilities(this.supports60, this.chosen, this.cameras,
      {bool? meetsMinimum,
      bool? meetsTarget,
      bool? anyMeetsMinimum,
      this.platform = 'android',
      this.autoKey,
      this.hiddenPhysicalIds = const [],
      this.raw = const {}})
      : meetsMinimum = meetsMinimum ?? supports60,
        meetsTarget = meetsTarget ?? supports60,
        anyMeetsMinimum = anyMeetsMinimum ?? (meetsMinimum ?? supports60);

  factory PpgCapabilities.fromMap(Map m) => PpgCapabilities(
        m['supports60'] == true,
        m['chosen'] == null ? null : Map<String, dynamic>.from(m['chosen']),
        [for (final c in (m['cameras'] as List)) PpgCameraInfo.fromMap(c as Map)],
        meetsMinimum: m['meetsMinimum'] as bool?, // absent from older native builds -> falls back to supports60
        meetsTarget: m['meetsTarget'] as bool?,
        anyMeetsMinimum: m['anyMeetsMinimum'] as bool?,
        platform: (m['platform'] as String?) ?? 'android',
        autoKey: m['autoKey'] as String?,
        hiddenPhysicalIds: [for (final h in (m['hiddenPhysicalIds'] as List? ?? const [])) h.toString()],
        raw: Map<String, dynamic>.from(m),
      );

  PpgCameraInfo? cameraByKey(String? key) {
    if (key == null) return null;
    for (final c in cameras) {
      if (c.key == key) return c;
    }
    return null;
  }

  PpgCameraInfo? get chosenCamera => cameraByKey(chosen?['key']?.toString() ?? chosen?['id']?.toString());

  /// Flash availability of the chosen camera (null if unknown).
  bool? get chosenHasFlash => chosenCamera?.hasFlash;

  /// Multi-line text for the diagnostics panel and for "copy diagnostics".
  String describe() {
    final b = StringBuffer();
    b.writeln('platform: $platform  cameras listed: ${cameras.length}'
        '${hiddenPhysicalIds.isEmpty ? '' : '  hidden physical lenses: ${hiddenPhysicalIds.join(', ')}'}');
    for (final c in cameras) {
      b.writeln('camera ${c.key} [${c.kind}] ${c.label}: flash=${c.hasFlash} manualSensor=${c.manualSensor} '
          'mode=${c.mode} usableFps=${c.usableFps} yuvMaxFps=${c.maxFps.toStringAsFixed(1)} videoMaxFps=${c.surfaceMaxFps.toStringAsFixed(1)} '
          'aeFps=${c.raw['aeFpsRanges']} highSpeed=${c.raw['highSpeedFpsRanges']} -> ${c.usable ? 'usable' : c.reason}');
    }
    b.write(meetsMinimum
        ? 'chosen: $chosen (reaches target: $meetsTarget)'
        : 'NO usable camera for the current selection (any camera usable: $anyMeetsMinimum)');
    return b.toString();
  }
}

/// One batch of frames. frames is stride-6: [t_s, R, G, B, fracSaturated, fracDark] per frame.
class PpgBatch {
  final Float64List frames;
  final int exposureNs, iso, frameDurationNs;
  final bool manual, locked;
  PpgBatch(this.frames, this.exposureNs, this.iso, this.frameDurationNs, this.manual, this.locked);
  int get count => frames.length ~/ 6;
}

class PpgCamera {
  static const _m = MethodChannel('agni/ppg_camera');
  static const _e = EventChannel('agni/ppg_camera/frames');

  /// [targetFps] / [minFps] come from the app's capture config (see app/lib/capture_validation.dart);
  /// the native side holds no thresholds of its own. [cameraKey] selects one camera (null = automatic).
  static Future<PpgCapabilities> capabilities({int targetFps = 60, int minFps = 55, String? cameraKey}) async =>
      PpgCapabilities.fromMap(await _m.invokeMethod('capabilities', {
        'targetFps': targetFps,
        'minFps': minFps,
        if (cameraKey != null) 'cameraKey': cameraKey,
      }) as Map);

  /// Listen to [batches] BEFORE calling start. Throws PlatformException(code: FPS_UNSUPPORTED |
  /// CAMERA_UNSUITABLE | NO_PERMISSION | CAMERA_IN_USE | OPEN_FAILED | SESSION_FAILED).
  static Future<Map<String, dynamic>> start({int targetFps = 60, int minFps = 55, String? cameraKey}) async =>
      Map<String, dynamic>.from(await _m.invokeMethod('start', {
        'targetFps': targetFps,
        'minFps': minFps,
        if (cameraKey != null) 'cameraKey': cameraKey,
      }) as Map);

  /// Native camera-permission request. Implemented on iOS (AVFoundation). On Android it only reports the current
  /// grant state; use permission_handler there (the app does).
  static Future<bool> requestCameraPermission() async =>
      (await _m.invokeMethod('requestPermission')) == true;

  static Future<void> setExposureLock(bool locked) => _m.invokeMethod('setExposureLock', {'locked': locked});
  static Future<void> stop() => _m.invokeMethod('stop');

  /// Step-by-step log of the running capture session (empty when none). For "Copy diagnostics".
  static Future<List<String>> diagnostics() async {
    try {
      return ((await _m.invokeMethod('diagnostics')) as List?)?.map((e) => e.toString()).toList() ?? const [];
    } on MissingPluginException {
      return const [];
    }
  }

  static Stream<PpgBatch> get batches => _e.receiveBroadcastStream().map((o) {
        final m = o as Map;
        return PpgBatch(m['frames'] as Float64List, (m['exposureNs'] as num).toInt(), (m['iso'] as num).toInt(),
            (m['frameDurationNs'] as num).toInt(), m['manual'] == true, m['locked'] == true);
      });
}
