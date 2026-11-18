import 'package:agni_pulse/prakriti.dart';
import 'package:flutter_test/flutter_test.dart';

Map<int, String> answers(int v, int p, int k) {
  final m = <int, String>{};
  var i = 0;
  for (var n = 0; n < v; n++) {
    m[i++] = 'V';
  }
  for (var n = 0; n < p; n++) {
    m[i++] = 'P';
  }
  for (var n = 0; n < k; n++) {
    m[i++] = 'K';
  }
  return m;
}

void main() {
  test('clear single dosha', () {
    final r = scorePrakriti(answers(2, 8, 2));
    expect(r.type, 'Pitta');
    expect(r.scores, {'vata': 2, 'pitta': 8, 'kapha': 2});
  });

  test('two doshas within one point are a dual type, in canonical order', () {
    expect(scorePrakriti(answers(5, 4, 3)).type, 'Vata-Pitta');
    expect(scorePrakriti(answers(1, 6, 5)).type, 'Pitta-Kapha');
    expect(scorePrakriti(answers(6, 1, 5)).type, 'Vata-Kapha');
  });

  test('all three within one point is Tridosha', () {
    expect(scorePrakriti(answers(4, 4, 4)).type, 'Tridosha');
    expect(scorePrakriti(answers(4, 4, 3)).type, 'Tridosha');
  });

  test('every result is a value the server accepts', () {
    const allowed = {
      'Vata',
      'Pitta',
      'Kapha',
      'Vata-Pitta',
      'Pitta-Kapha',
      'Vata-Kapha',
      'Tridosha'
    };
    for (var v = 0; v <= 12; v++) {
      for (var p = 0; p <= 12 - v; p++) {
        final r = scorePrakriti(answers(v, p, 12 - v - p));
        expect(allowed.contains(r.type), isTrue,
            reason: '$v/$p/${12 - v - p} -> ${r.type}');
        expect(prakritiDescriptions.containsKey(r.type), isTrue);
      }
    }
  });

  test('question bank is complete', () {
    expect(prakritiQuestions.length, 12);
    for (final q in prakritiQuestions) {
      expect(q.options.map((o) => o.dosha).toSet(), {'V', 'P', 'K'});
    }
  });
}
