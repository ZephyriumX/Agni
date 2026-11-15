import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:agni_pulse/signal_monitor.dart';

void main() {
  test('finger detection needs sustained red-dominant frames (hysteresis)', () {
    final m = SignalMonitor();
    for (var i = 0; i < 5; i++) { m.add(i / 60, 200, 60, 20, 0, 0); }
    expect(m.finger, isFalse);
    for (var i = 5; i < 30; i++) { m.add(i / 60, 200, 60, 20, 0, 0); }
    expect(m.finger, isTrue);
    for (var i = 30; i < 40; i++) { m.add(i / 60, 30, 30, 30, 0, 0.9); }
    expect(m.finger, isTrue); // brief glitch tolerated
    for (var i = 40; i < 80; i++) { m.add(i / 60, 30, 30, 30, 0, 0.9); }
    expect(m.finger, isFalse);
  });

  test('display PPG follows an inverted 1.2 Hz pulse', () {
    final m = SignalMonitor();
    for (var i = 0; i < 600; i++) {
      final t = i / 60;
      m.add(t, 180 - 2 * math.sin(2 * math.pi * 1.2 * t), 60, 20, 0, 0);
    }
    expect(m.displayPpg().length, greaterThan(100));
    expect(m.perfusion(), greaterThan(0.005));
  });
}
