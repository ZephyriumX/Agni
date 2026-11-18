import 'package:agni_pulse/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 18, 12);

  test('relative day labels', () {
    expect(fmtDay(DateTime(2026, 11, 18, 8), now: now), 'Today');
    expect(fmtDay(DateTime(2026, 11, 17, 23), now: now), 'Yesterday');
    expect(fmtDay(DateTime(2026, 11, 16, 9), now: now), 'Mon 16 Nov');
    expect(fmtDay(DateTime(2025, 3, 2), now: now), '2 Mar 2025');
  });

  test('numbers', () {
    expect(num1(41.26), '41.3');
    expect(num1(null), '—');
    expect(signed(3.0, 1, ' ms'), '+3.0 ms');
    expect(signed(-1.25, 2), '-1.25');
    expect(pct(56.9), '57%');
  });

  test('ago', () {
    expect(
        ago(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
    expect(ago(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
  });

  test('tag labels', () {
    expect(tagLabel('Post-Meal'), 'After meal');
    expect(tagLabel(null), '—');
    expect(tagLabel('Something-New'), 'Something-New');
    expect(capitalise('non_vegetarian'), 'Non vegetarian');
  });
}
