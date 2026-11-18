/// Prakriti (Ayurvedic constitution) self-assessment. Traditional wellness framing only, not a diagnosis.
/// Pure Dart so the scoring is unit-tested (test/prakriti_test.dart).
class PrakritiQuestion {
  final String title;
  final String? hint;
  final List<PrakritiOption> options;
  const PrakritiQuestion(this.title, this.options, {this.hint});
}

class PrakritiOption {
  final String label;
  final String dosha; // V | P | K
  const PrakritiOption(this.label, this.dosha);
}

const prakritiQuestions = <PrakritiQuestion>[
  PrakritiQuestion('Body frame', [
    PrakritiOption('Thin, light, hard to gain weight', 'V'),
    PrakritiOption('Medium, muscular', 'P'),
    PrakritiOption('Broad, solid, gains weight easily', 'K'),
  ]),
  PrakritiQuestion('Skin', [
    PrakritiOption('Dry, rough, cool', 'V'),
    PrakritiOption('Warm, sensitive, prone to redness', 'P'),
    PrakritiOption('Smooth, oily, cool', 'K'),
  ]),
  PrakritiQuestion('Hair', [
    PrakritiOption('Dry, frizzy or thin', 'V'),
    PrakritiOption('Fine, early greying or thinning', 'P'),
    PrakritiOption('Thick, wavy, lustrous', 'K'),
  ]),
  PrakritiQuestion('Appetite', [
    PrakritiOption('Irregular, sometimes forget to eat', 'V'),
    PrakritiOption('Strong, irritable if a meal is late', 'P'),
    PrakritiOption('Steady, can skip meals easily', 'K'),
  ]),
  PrakritiQuestion('Digestion', [
    PrakritiOption('Gas or bloating, irregular', 'V'),
    PrakritiOption('Quick; acidity or heartburn at times', 'P'),
    PrakritiOption('Slow; heavy feeling after meals', 'K'),
  ]),
  PrakritiQuestion('Sleep', [
    PrakritiOption('Light, easily disturbed', 'V'),
    PrakritiOption('Moderate; wake up warm', 'P'),
    PrakritiOption('Deep and long; hard to wake', 'K'),
  ]),
  PrakritiQuestion('Under stress you tend to be', [
    PrakritiOption('Anxious, worried', 'V'),
    PrakritiOption('Irritable, intense', 'P'),
    PrakritiOption('Withdrawn, calm, slow to react', 'K'),
  ]),
  PrakritiQuestion('Energy through the day', [
    PrakritiOption('Comes in bursts, tire quickly', 'V'),
    PrakritiOption('Strong and focused', 'P'),
    PrakritiOption('Steady, slow to start', 'K'),
  ]),
  PrakritiQuestion('Weather you dislike most', [
    PrakritiOption('Cold, dry, windy', 'V'),
    PrakritiOption('Hot, humid sun', 'P'),
    PrakritiOption('Cold and damp', 'K'),
  ]),
  PrakritiQuestion('Speech', [
    PrakritiOption('Fast, talkative', 'V'),
    PrakritiOption('Sharp, precise', 'P'),
    PrakritiOption('Slow, calm, measured', 'K'),
  ]),
  PrakritiQuestion('Memory', [
    PrakritiOption('Learn quickly, forget quickly', 'V'),
    PrakritiOption('Sharp and clear', 'P'),
    PrakritiOption('Slow to learn, never forget', 'K'),
  ]),
  PrakritiQuestion('Body temperature', [
    PrakritiOption('Hands and feet often cold', 'V'),
    PrakritiOption('Usually feel warm', 'P'),
    PrakritiOption('Comfortable; cool and steady', 'K'),
  ]),
];

class PrakritiResult {
  final int vata, pitta, kapha;
  final String type; // value accepted by the server
  const PrakritiResult(this.vata, this.pitta, this.kapha, this.type);

  int get total => vata + pitta + kapha;
  double share(String d) => total == 0
      ? 0
      : (d == 'V'
              ? vata
              : d == 'P'
                  ? pitta
                  : kapha) /
          total;
  Map<String, int> get scores => {'vata': vata, 'pitta': pitta, 'kapha': kapha};
}

/// [answers]: question index -> 'V' | 'P' | 'K'.
/// A dosha "leads" if its count is within 1 of the top count (so 5/4/3 is a dual type, 6/3/3 is single).
/// All three within 1 of each other = Tridosha.
PrakritiResult scorePrakriti(Map<int, String> answers) {
  var v = 0, p = 0, k = 0;
  for (final a in answers.values) {
    if (a == 'V') v++;
    if (a == 'P') p++;
    if (a == 'K') k++;
  }
  final counts = {'V': v, 'P': p, 'K': k};
  final top = [v, p, k].reduce((a, b) => a > b ? a : b);
  final lead = counts.entries
      .where((e) => top - e.value <= 1)
      .map((e) => e.key)
      .toList()
    ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  String type;
  if (lead.length == 3) {
    type = 'Tridosha';
  } else if (lead.length == 2) {
    final s = lead.toSet();
    if (s.containsAll({'V', 'P'})) {
      type = 'Vata-Pitta';
    } else if (s.containsAll({'P', 'K'})) {
      type = 'Pitta-Kapha';
    } else {
      type = 'Vata-Kapha';
    }
  } else {
    type = const {'V': 'Vata', 'P': 'Pitta', 'K': 'Kapha'}[lead.first]!;
  }
  return PrakritiResult(v, p, k, type);
}

const prakritiDescriptions = {
  'Vata':
      'Air and space: quick, creative and light. Benefits most from routine, warmth and regular meals.',
  'Pitta':
      'Fire and water: focused, sharp and warm. Benefits most from cooling foods and avoiding overheating.',
  'Kapha':
      'Earth and water: steady, calm and strong. Benefits most from activity and lighter meals.',
  'Vata-Pitta':
      'Quick and driven. Balance with regular, warm but not spicy meals and calm routines.',
  'Pitta-Kapha':
      'Strong and steady. Balance with light, not too spicy meals and regular activity.',
  'Vata-Kapha':
      'Light yet steady. Balance with warm, light, cooked meals and gentle activity.',
  'Tridosha':
      'All three in balance. Keep a regular routine and notice what shifts you.',
};
