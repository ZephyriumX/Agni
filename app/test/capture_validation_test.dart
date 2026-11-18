import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:agni_pulse/capture_validation.dart';

/// Rebuilds the deterministic timestamps described in docs/capture_validation_vectors.json
/// (same integer arithmetic as backend/tests/vectors.py).
List<double> build(Map<String, dynamic> spec) {
  var t = <double>[];
  var t0 = 0.0;
  for (final seg in spec['segments'] as List) {
    final dur = (seg[0] as num).toDouble(), fps = (seg[1] as num).toDouble();
    final n = (dur * fps).round();
    for (var k = 0; k < n; k++) {
      t.add(t0 + k / fps);
    }
    t0 += n / fps;
  }
  for (final d in (spec['delete'] as List? ?? const [])) {
    final drop = <int>{
      for (var i = d[0] as int; i < (d[1] as int); i += d[2] as int) i
    };
    t = [
      for (var i = 0; i < t.length; i++)
        if (!drop.contains(i)) t[i]
    ];
  }
  return t;
}

List<double> uniform(double fps, [double dur = 35]) =>
    [for (var i = 0; i * (1 / fps) < dur; i++) i / fps];

void main() {
  test('Dart validator agrees with the Python validator on every golden vector',
      () {
    // `flutter test` runs with cwd = app/
    final f = File('../docs/capture_validation_vectors.json');
    expect(f.existsSync(), isTrue,
        reason: 'run flutter test from the app/ directory');
    final doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final vectors = doc['vectors'] as List;
    expect(vectors, isNotEmpty);
    for (final v in vectors) {
      final r = evaluateTimestamps(build(v as Map<String, dynamic>));
      final exp = v['expect'] as Map<String, dynamic>;
      expect(statusLabel(r.status), exp['status'],
          reason: '${v['name']}: ${r.messages}');
      expect(r.codes.toList()..sort(), (exp['codes'] as List).cast<String>(),
          reason: v['name'] as String);
    }
  });

  test('invalid, non-finite and non-monotonic timestamps fail', () {
    expect(evaluateTimestamps([]).status, CaptureStatus.fail);
    expect(evaluateTimestamps(List.filled(30, double.nan)).codes,
        contains('timestamps_invalid'));
    final t = uniform(60);
    final dup = [...t.sublist(0, 50), ...t.sublist(49)];
    expect(evaluateTimestamps(dup).codes, contains('timestamps_not_monotonic'));
    expect(evaluateTimestamps([for (final x in uniform(60)) x * 1000]).status,
        CaptureStatus.fail);
    expect(evaluateTimestamps([for (final x in uniform(60)) x / 1000]).codes,
        contains('timestamps_implausible'));
  });

  test('config parsing, defaults and native fps hand-off', () {
    final c = CaptureConfig.fromJson({'hard_min_fps': 52, 'unknown': 1});
    expect(c.hardMinFps, 52);
    expect(c.targetFps, 60);
    expect(CaptureConfig.defaults.nativeMinFps, 55);
    expect(CaptureConfig.defaults.nativeTargetFps, 60);
    final strict =
        CaptureConfig.fromJson({'hard_min_fps': 59, 'preferred_min_fps': 59.5});
    expect(evaluateTimestamps(uniform(58), strict).status, CaptureStatus.fail);
  });

  test('timing and SQI are separate gates and FAIL always wins', () {
    expect(combineStatus(CaptureStatus.pass, true), CaptureStatus.pass);
    expect(combineStatus(CaptureStatus.pass, false), CaptureStatus.fail);
    expect(combineStatus(CaptureStatus.warning, true), CaptureStatus.warning);
    expect(combineStatus(CaptureStatus.fail, true), CaptureStatus.fail);
    expect(combineStatus(null, true), CaptureStatus.warning);
  });
}
