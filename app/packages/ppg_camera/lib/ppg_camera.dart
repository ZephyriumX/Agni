import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Capabilities as reported by Camera2 (not guesses).
class PpgCapabilities {
  /// Legacy flag: a stream that advertises >= 60 fps exists.
  final bool supports60;

  /// A usable camera/stream exists at or above the requested MINIMUM fps (the hard minimum, e.g. 55).
  /// This is only a hardware pre-check; the real verdict comes from the recorded sensor timestamps.
  final bool meetsMinimum;

  /// A stream at or above the requested TARGET fps exists.
  final bool meetsTarget;

  /// 'android' (Camera2). Reserved for 'ios' (AVFoundation) so the UI can show the platform.
  final String platform;
  final Map<String, dynamic>? chosen;
  final List<Map<String, dynamic>> cameras;
  PpgCapabilities(this.supports60, this.chosen, this.cameras,
      {bool? meetsMinimum, bool? meetsTarget, this.platform = 'android'})
      : meetsMinimum = meetsMinimum ?? supports60,
        meetsTarget = meetsTarget ?? supports60;

  factory PpgCapabilities.fromMap(Map m) => PpgCapabilities(
        m['supports60'] == true,
        m['chosen'] == null ? null : Map<String, dynamic>.from(m['chosen']),
        [for (final c in (m['cameras'] as List)) Map<String, dynamic>.from(c)],
        meetsMinimum: m['meetsMinimum']
            as bool?, // absent from older native builds -> falls back to supports60
        meetsTarget: m['meetsTarget'] as bool?,
        platform: (m['platform'] as String?) ?? 'android',
      );

  /// Flash availability of the chosen camera (null if unknown).
  bool? get chosenHasFlash {
    final id = chosen?['id'];
    for (final c in cameras) {
      if (c['id'] == id) return c['hasFlash'] == true;
    }
    return null;
  }

  String describe() {
    final b = StringBuffer();
    for (final c in cameras) {
      b.writeln(
          'camera ${c['id']}: flash=${c['hasFlash']} manualSensor=${c['manualSensor']} '
          'aeFps=${c['aeFpsRanges']} maxYuvFps=${(c['maxYuvFps'] as num).toStringAsFixed(1)}');
    }
    b.write(meetsMinimum
        ? 'chosen: $chosen (stream reaches target: $meetsTarget)'
        : 'NO camera/stream combination reaches the minimum fps');
    return b.toString();
  }
}

/// One batch of frames. frames is stride-6: [t_s, R, G, B, fracSaturated, fracDark] per frame.
class PpgBatch {
  final Float64List frames;
  final int exposureNs, iso, frameDurationNs;
  final bool manual, locked;
  PpgBatch(this.frames, this.exposureNs, this.iso, this.frameDurationNs,
      this.manual, this.locked);
  int get count => frames.length ~/ 6;
}

class PpgCamera {
  static const _m = MethodChannel('agni/ppg_camera');
  static const _e = EventChannel('agni/ppg_camera/frames');

  /// [targetFps] / [minFps] come from the app's capture config (see app/lib/capture_validation.dart);
  /// the native side holds no thresholds of its own.
  static Future<PpgCapabilities> capabilities(
          {int targetFps = 60, int minFps = 55}) async =>
      PpgCapabilities.fromMap(await _m.invokeMethod(
          'capabilities', {'targetFps': targetFps, 'minFps': minFps}) as Map);

  /// Listen to [batches] BEFORE calling start. Throws PlatformException(code: FPS_UNSUPPORTED |
  /// NO_PERMISSION | CAMERA_IN_USE | OPEN_FAILED | SESSION_FAILED).
  static Future<Map<String, dynamic>> start(
          {int targetFps = 60, int minFps = 55}) async =>
      Map<String, dynamic>.from(await _m.invokeMethod(
          'start', {'targetFps': targetFps, 'minFps': minFps}) as Map);

  static Future<void> setExposureLock(bool locked) =>
      _m.invokeMethod('setExposureLock', {'locked': locked});
  static Future<void> stop() => _m.invokeMethod('stop');

  static Stream<PpgBatch> get batches => _e.receiveBroadcastStream().map((o) {
        final m = o as Map;
        return PpgBatch(
            m['frames'] as Float64List,
            (m['exposureNs'] as num).toInt(),
            (m['iso'] as num).toInt(),
            (m['frameDurationNs'] as num).toInt(),
            m['manual'] == true,
            m['locked'] == true);
      });
}
