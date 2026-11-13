import 'package:flutter/material.dart';
import 'waveform.dart';

String _f(dynamic v, [int d = 1]) =>
    v == null ? '—' : (v as num).toStringAsFixed(d);

Color gradeColor(String g) =>
    g == 'Good' ? Colors.green : (g == 'Bad' ? Colors.red : Colors.orange);

class ResultView extends StatelessWidget {
  final Map<String, dynamic> result;
  final VoidCallback? onVajrasana;
  const ResultView({super.key, required this.result, this.onVajrasana});

  @override
  Widget build(BuildContext context) {
    final sqi = Map<String, dynamic>.from(result['sqi']);
    final ok = sqi['passed'] == true;
    final reasons = List<String>.from(sqi['reasons'] ?? []);
    final warnings = List<String>.from(result['warnings'] ?? []);
    final comp = result['comparison'] == null
        ? null
        : Map<String, dynamic>.from(result['comparison']);
    final acq = result['acquisition'] == null
        ? null
        : Map<String, dynamic>.from(result['acquisition']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (result['duplicate'] == true)
        const Text('(already saved - duplicate upload ignored)'),
      Chip(
        avatar: Icon(ok ? Icons.check : Icons.warning, size: 18),
        label:
            Text(ok ? 'Signal quality: good' : 'Signal quality: poor — rescan'),
        backgroundColor: ok ? Colors.green.shade100 : Colors.orange.shade100,
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 12, runSpacing: 12, children: [
        _tile('b/a (vascular)', _f(result['ba_ratio'], 2),
            'more negative = more compliant'),
        _tile('RMSSD', '${_f(result['rmssd_ms'])} ms', 'autonomic stress'),
        _tile('Heart rate', '${_f(result['avg_bpm'], 0)} bpm', ''),
        _tile('d/a', _f(result['da_ratio'], 2), 'experimental'),
      ]),
      for (final r in reasons)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('• $r')),
      for (final w in warnings)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('ℹ $w')),
      // Older stored scans have no 'status' in acquisition: the line is simply omitted for them.
      if (acq != null && acq['status'] != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              'Capture timing: ${acq['status']}'
              '${result['final_status'] != null ? '   |   Final result: ${result['final_status']}' : ''}',
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      if (acq != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              'Measured ${_f(acq['fs_mean'])} fps, ${_f((acq['drop_fraction'] as num) * 100)}% dropped frames, '
              'processed in ${_f(result['processing_ms'], 0)} ms',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
      if (comp != null) ...[
        const Divider(height: 28),
        ComparisonCard(comparison: comp, onVajrasana: onVajrasana),
      ],
      const SizedBox(height: 8),
      Text(result['disclaimer'] ?? '',
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  Widget _tile(String t, String v, String s) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: const TextStyle(fontSize: 12)),
            Text(v,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            if (s.isNotEmpty)
              Text(s, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
        ),
      );
}

/// Reaction Report (3 dials), compatibility, and Digital Cure suggestions for one comparison.
class ComparisonCard extends StatelessWidget {
  final Map<String, dynamic> comparison;
  final VoidCallback? onVajrasana;
  const ComparisonCard({super.key, required this.comparison, this.onVajrasana});

  @override
  Widget build(BuildContext context) {
    final interp =
        Map<String, dynamic>.from(comparison['interpretation'] ?? {});
    final dials = Map<String, dynamic>.from(interp['dials'] ?? {});
    final recs = List<Map<String, dynamic>>.from(
        (interp['recommendations'] ?? [])
            .map((e) => Map<String, dynamic>.from(e)));
    final wantsVajra =
        recs.any((r) => (r['type'] as String).contains('Vajrasana'));
    const dialNames = {
      'metabolic_load': 'Metabolic load',
      'digestive_fire': 'Digestive fire',
      'stability': 'Stability'
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Compared with your reference scan',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
          'Compatibility ${_f(comparison['compatibility_pct'], 0)}%  ·  ${comparison['verdict'] ?? ''}',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      Text(
          'Δ Vascular tone ${_f(comparison['delta_vascular_tone_pct'])} %   ·   HRV ratio ${_f(comparison['hrv_ratio'], 2)}'),
      const SizedBox(height: 8),
      Row(children: [
        for (final e in dialNames.entries)
          if (dials[e.key] != null)
            Expanded(
              child: Card(
                color: gradeColor(dials[e.key]['grade']).withOpacity(0.15),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(children: [
                    Text(e.value, style: const TextStyle(fontSize: 11)),
                    Text(dials[e.key]['grade'],
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: gradeColor(dials[e.key]['grade']))),
                    Text(dials[e.key]['label'] ?? '',
                        style: const TextStyle(fontSize: 10),
                        textAlign: TextAlign.center),
                  ]),
                ),
              ),
            ),
      ]),
      for (final f in List<String>.from(interp['findings'] ?? [])) Text('• $f'),
      const SizedBox(height: 8),
      for (final r in recs)
        Text('🧘 ${r['type']}: ${r['how']}',
            style: const TextStyle(fontStyle: FontStyle.italic)),
      if (wantsVajra && onVajrasana != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: FilledButton.tonal(
              onPressed: onVajrasana,
              child: const Text('Start 10-min Vajrasana timer')),
        ),
      const SizedBox(height: 4),
      const Text(
          'Wellness guidance, not medical advice. "Metabolic overload" is an experimental pulse-shape pattern, not a glucose reading.',
          style: TextStyle(fontSize: 11, color: Colors.grey)),
    ]);
  }
}

/// Before vs after: ensemble-average APG beats from two scans' backend templates.
class BeforeAfterCard extends StatelessWidget {
  final Map<String, dynamic>? before, after;
  const BeforeAfterCard({super.key, this.before, this.after});

  List<double> _apg(Map<String, dynamic>? t) => t == null
      ? const []
      : List<double>.from((t['apg'] as List).map((e) => (e as num).toDouble()));

  @override
  Widget build(BuildContext context) {
    final b = _apg(before), a = _apg(after);
    if (b.isEmpty || a.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Before vs after (average APG beat)',
          style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(
          height: 140,
          child: CustomPaint(
              painter: BeforeAfterPainter(b, a), size: Size.infinite)),
      const Row(children: [
        Icon(Icons.circle, size: 10, color: Colors.grey),
        SizedBox(width: 4),
        Text('before  '),
        Icon(Icons.circle, size: 10, color: Colors.deepOrange),
        SizedBox(width: 4),
        Text('after'),
      ]),
    ]);
  }
}
