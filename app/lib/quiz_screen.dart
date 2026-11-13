import 'package:flutter/material.dart';
import 'api.dart';

/// PRD View 1: short Prakriti (dosha) questionnaire. Self-assessment only - not a diagnosis.
class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key});
  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _Q {
  final String title;
  final List<List<String>> opts; // [label, V|P|K]
  const _Q(this.title, this.opts);
}

const _qs = <_Q>[
  _Q('Body frame', [
    ['Thin, light', 'V'],
    ['Medium, muscular', 'P'],
    ['Broad, sturdy', 'K']
  ]),
  _Q('Skin', [
    ['Dry, rough', 'V'],
    ['Warm, sensitive, prone to redness', 'P'],
    ['Smooth, oily', 'K']
  ]),
  _Q('Appetite', [
    ['Irregular', 'V'],
    ['Strong, gets irritable if late', 'P'],
    ['Steady, can skip meals', 'K']
  ]),
  _Q('Under stress you tend to be', [
    ['Anxious, worried', 'V'],
    ['Irritable, intense', 'P'],
    ['Withdrawn, calm', 'K']
  ]),
  _Q('Sleep', [
    ['Light, interrupted', 'V'],
    ['Moderate, wake hot', 'P'],
    ['Deep, long', 'K']
  ]),
  _Q('Climate you dislike most', [
    ['Cold, windy', 'V'],
    ['Hot', 'P'],
    ['Cold, damp', 'K']
  ]),
];

class _QuizScreenState extends State<QuizScreen> {
  final _ans = <int, String>{};
  bool _saving = false;
  String? _msg;

  String _result() {
    final c = {'V': 0, 'P': 0, 'K': 0};
    for (final a in _ans.values) {
      c[a] = c[a]! + 1;
    }
    final top = c.values.reduce((a, b) => a > b ? a : b);
    final lead =
        c.entries.where((e) => e.value == top).map((e) => e.key).toSet();
    const names = {'V': 'Vata', 'P': 'Pitta', 'K': 'Kapha'};
    if (lead.length == 3) return 'Tridosha';
    if (lead.length == 2) {
      if (lead.containsAll({'V', 'P'})) return 'Vata-Pitta';
      if (lead.containsAll({'P', 'K'})) return 'Pitta-Kapha';
      return 'Vata-Kapha';
    }
    return names[lead.first]!;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _msg = null;
    });
    try {
      final p = _result();
      await Api.setPrakriti(p);
      if (mounted) Navigator.pop(context, p);
    } on ApiError catch (e) {
      setState(() {
        _msg = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Prakriti quiz')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (var i = 0; i < _qs.length; i++) ...[
          Text(_qs[i].title,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          for (final o in _qs[i].opts)
            RadioListTile<String>(
              dense: true,
              title: Text(o[0]),
              value: o[1],
              groupValue: _ans[i],
              onChanged: (v) => setState(() => _ans[i] = v!),
            ),
          const SizedBox(height: 8),
        ],
        if (_msg != null)
          Text(_msg!, style: const TextStyle(color: Colors.red)),
        FilledButton(
            onPressed: _ans.length == _qs.length && !_saving ? _save : null,
            child: const Text('Save my Prakriti')),
        const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Self-assessment for wellness context only.',
                style: TextStyle(fontSize: 11, color: Colors.grey))),
      ]),
    );
  }
}
