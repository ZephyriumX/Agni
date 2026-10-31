import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Capabilities as reported by Camera2 (not guesses).
class PpgCapabilities {
  final bool supports60;
  final Map<String, dynamic>? chosen;
  final List<Map<String, dynamic>> cameras;
  PpgCapabilities(this.supports60, this.chosen, this.cameras);

  factory PpgCapabilities.fromMap(Map m) => PpgCapabilities(
        m['supports60'] == true,
        m['chosen'] == null ? null : Map<String, dynamic>.from(m['chosen']),
        [for (final c in (m['cameras'] as List)) Map<String, dynamic>.from(c)],
      );

  String describe() {
    final b = StringBuffer();
    for (final c in cameras) {
      b.writeln('camera ${c['id']}: flash=${c['hasFlash']} manualSensor=${c['manualSensor']} '
          'aeFps=${c['aeFpsRanges']} maxYuvFps=${(c['maxYuvFps'] as num).toStringAsFixed(1)}');
    }
    b.write(supports60 ? 'chosen: $chosen' : 'NO camera/stream combination reaches 60 fps');
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

  static Future<PpgCapabilities> capabilities() async =>
      PpgCapabilities.fromMap(await _m.invokeMethod('capabilities') as Map);

  /// Listen to [batches] BEFORE calling start. Throws PlatformException(code: FPS_UNSUPPORTED |
  /// NO_PERMISSION | CAMERA_IN_USE | OPEN_FAILED | SESSION_FAILED).
  static Future<Map<String, dynamic>> start({int targetFps = 60}) async =>
      Map<String, dynamic>.from(await _m.invokeMethod('start', {'targetFps': targetFps}) as Map);

  static Future<void> setExposureLock(bool locked) => _m.invokeMethod('setExposureLock', {'locked': locked});
  static Future<void> stop() => _m.invokeMethod('stop');

  static Stream<PpgBatch> get batches => _e.receiveBroadcastStream().map((o) {
        final m = o as Map;
        return PpgBatch(m['frames'] as Float64List, (m['exposureNs'] as num).toInt(), (m['iso'] as num).toInt(),
            (m['frameDurationNs'] as num).toInt(), m['manual'] == true, m['locked'] == true);
      });
}
