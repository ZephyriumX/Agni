import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'api.dart';
import 'result_view.dart';
import 'scan_screen.dart';

/// PRD View 7 "Digital Pharmacy": 10-minute Vajrasana timer, then a Post-Vajrasana scan that is
/// compared against the scan taken before it (PRD F5 before/after).
class TimerScreen extends StatefulWidget {
  final String preScanId;
  const TimerScreen({super.key, required this.preScanId});
  @override
  State<TimerScreen> createState() => _TimerScreenState();
}

class _TimerScreenState extends State<TimerScreen> {
  static const total = 10 * 60;
  int _left = total;
  Timer? _timer;
  bool _running = false;
  Map<String, dynamic>? _after, _beforeScan;

  void _toggle() {
    if (_running) {
      _timer?.cancel();
      WakelockPlus.disable();
      setState(() => _running = false);
      return;
    }
    WakelockPlus.enable();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_left <= 1) {
        t.cancel();
        WakelockPlus.disable();
        setState(() {
          _left = 0;
          _running = false;
        });
      } else {
        setState(() => _left--);
      }
    });
    setState(() => _running = true);
  }

  Future<void> _scan() async {
    final res = await Navigator.push<Object?>(
        context,
        MaterialPageRoute(
            builder: (_) => ScanScreen(
                initialTag: 'Post-Vajrasana', compareTo: widget.preScanId)));
    if (res is! Map || res['scan_id'] == null) return;
    try {
      final before = await Api.scan(widget.preScanId);
      final after = await Api.scan(res['scan_id'] as String);
      if (mounted)
        setState(() {
          _after = after;
          _beforeScan = before;
        });
    } on ApiError catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = (_left ~/ 60).toString().padLeft(2, '0'),
        s = (_left % 60).toString().padLeft(2, '0');
    final bt = _beforeScan?['template'], at = _after?['template'];
    return Scaffold(
      appBar: AppBar(title: const Text('Vajrasana')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        const Text(
            'Kneel and sit back on your heels, spine upright, hands on thighs. Breathe slowly through the nose.'),
        const SizedBox(height: 24),
        Center(
            child: Text('$m:$s',
                style: const TextStyle(
                    fontSize: 64, fontWeight: FontWeight.bold))),
        const SizedBox(height: 16),
        FilledButton(
            onPressed: _left == 0 ? null : _toggle,
            child: Text(
                _running ? 'Pause' : (_left == total ? 'Start' : 'Resume'))),
        const SizedBox(height: 12),
        FilledButton.tonal(
            onPressed: _scan,
            child: Text(_left == 0
                ? 'Scan now (Post-Vajrasana)'
                : 'Skip ahead and scan now')),
        if (_after != null) ...[
          const Divider(height: 32),
          BeforeAfterCard(
              before: bt == null ? null : Map<String, dynamic>.from(bt),
              after: at == null ? null : Map<String, dynamic>.from(at)),
          Text(
              'b/a before ${(_beforeScan?['ba_ratio'] as num?)?.toStringAsFixed(2) ?? '—'}  →  after ${(_after?['ba_ratio'] as num?)?.toStringAsFixed(2) ?? '—'}'),
          const Text(
              'Single-scan changes vary; repeat over several days before drawing conclusions.',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ]),
    );
  }
}
