import 'package:flutter/material.dart';

import 'api.dart';
import 'capture_validation.dart';
import 'format.dart';
import 'history_screen.dart';
import 'result_view.dart';
import 'waveform.dart';
import 'widgets.dart';

/// One stored scan: metrics, how it compares with the baseline, signal quality, waveform; delete; compare.
class ScanDetailScreen extends StatefulWidget {
  final String scanId;
  const ScanDetailScreen({super.key, required this.scanId});
  @override
  State<ScanDetailScreen> createState() => _ScanDetailScreenState();
}

class _ScanDetailScreenState extends State<ScanDetailScreen> {
  late Future<(Map<String, dynamic>, List<Map<String, dynamic>>)> _f = _load();

  Future<(Map<String, dynamic>, List<Map<String, dynamic>>)> _load() async {
    final scan = await Api.scan(widget.scanId);
    var comps = <Map<String, dynamic>>[];
    try {
      final rep = await Api.report();
      comps = ((rep['comparisons'] as List?) ?? const <dynamic>[])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((c) => c['test_scan_id'] == widget.scanId)
          .toList();
    } on ApiError catch (_) {}
    return (scan, comps);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this scan?'),
        content: const Text(
            'It is removed from your history, analytics and any comparisons. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.deleteScan(widget.scanId);
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan details'), actions: [
        IconButton(
          tooltip: 'Compare with another scan',
          icon: const Icon(Icons.compare_arrows),
          onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                  builder: (_) => CompareScreen(testScanId: widget.scanId))),
        ),
        IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete),
      ]),
      body: FutureBuilder<(Map<String, dynamic>, List<Map<String, dynamic>>)>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done)
            return const LoadingView();
          if (s.hasError)
            return ErrorView(
                error: s.error!, onRetry: () => setState(() => _f = _load()));
          final (scan, comps) = s.data!;
          return _body(scan, comps);
        },
      ),
    );
  }

  Widget _body(Map<String, dynamic> sc, List<Map<String, dynamic>> comps) {
    final cs = Theme.of(context).colorScheme;
    final ok = sc['sqi_passed'] == true;
    final t = parseTs(sc['timestamp']);
    final features = Map<String, dynamic>.from(
        (sc['features'] ?? const <String, dynamic>{}) as Map);
    final acq = Map<String, dynamic>.from(
        (features['acquisition'] ?? const <String, dynamic>{}) as Map);
    final sqi = Map<String, dynamic>.from(
        (sc['sqi_report'] ?? const <String, dynamic>{}) as Map);
    final tpl = sc['template'] == null
        ? null
        : Map<String, dynamic>.from(sc['template'] as Map);
    List<double> series(String k) => ((tpl?[k] as List?) ?? const <dynamic>[])
        .map((e) => (e as num).toDouble())
        .toList();
    final ctx = ((sc['context_tags'] as List?) ?? const <dynamic>[])
        .map((e) => '$e')
        .toList();
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Row(children: [
            CircleAvatar(
                radius: 24,
                backgroundColor:
                    tagColor(sc['tag_event'] as String?).withAlpha(40),
                child: Icon(tagIcon(sc['tag_event'] as String?),
                    color: tagColor(sc['tag_event'] as String?))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tagLabel(sc['tag_event'] as String?),
                        style: Theme.of(context).textTheme.titleLarge),
                    Text(t == null ? '' : '${fmtDay(t)}, ${fmtTime(t)}',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  ]),
            ),
            StatusPill(
                status: ok ? CaptureStatus.pass : CaptureStatus.fail,
                label: ok ? 'Good quality' : 'Rejected'),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (sc['intervention'] != null)
              Chip(
                  avatar: const Icon(Icons.self_improvement, size: 16),
                  label: Text('${sc['intervention']}')),
            for (final c in ctx) Chip(label: Text(c)),
          ]),
          if (sc['notes'] != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Note: ${sc['notes']}')),
          const SizedBox(height: 12),
          if (ok)
            Wrap(spacing: 10, runSpacing: 10, children: [
              MetricTile(
                  label: 'HRV (RMSSD)',
                  value: num1(sc['rmssd'], 0),
                  unit: 'ms'),
              MetricTile(
                  label: 'Heart rate',
                  value: num1(sc['avg_bpm'], 0),
                  unit: 'bpm'),
              MetricTile(
                  label: 'b/a ratio',
                  value: num1(sc['ba_ratio'], 2),
                  hint: 'more negative = more elastic'),
              MetricTile(
                  label: 'd/a ratio',
                  value: num1(features['da_ratio'], 2),
                  hint: 'experimental'),
            ])
          else
            InfoBanner(
              tone: CaptureStatus.fail,
              text:
                  'This scan did not pass the signal-quality check, so no values were calculated from it.\n'
                  '${((sqi['reasons'] as List?) ?? const <dynamic>[]).map((e) => '• $e').join('\n')}',
            ),
          if (tpl != null && series('apg').isNotEmpty)
            SectionCard(
              title: 'Average pulse beat',
              icon: Icons.show_chart,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 150,
                      child: CustomPaint(
                          painter: WaveformPainter(series('ppg'), series('apg'),
                              Colors.deepOrange, Colors.indigo),
                          size: Size.infinite),
                    ),
                    Text(
                        'Top: pulse wave (PPG). Bottom: its second derivative (APG), where the a and b waves give b/a.',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ]),
            ),
          for (final k in comps)
            SectionCard(child: ComparisonCard(comparison: k)),
          SectionCard(
            title: 'Capture & signal quality',
            icon: Icons.sensors,
            child: Text(
              [
                'Frame rate: ${num1(acq['fs_mean'])} fps (${acq['status'] ?? 'not recorded'})',
                'Dropped frames: ${acq['drop_fraction'] is num ? ((acq['drop_fraction'] as num) * 100).toStringAsFixed(1) : '—'} %',
                'Duration: ${num1(sc['duration_s'], 0)} s · beats ${features['n_beats'] ?? '—'}',
                'Signal-to-noise: ${num1(sqi['snr_db'])} dB · perfusion ${num1(sqi['perfusion_index_pct'], 2)} %',
                'Beat similarity: ${num1(sqi['template_correlation'], 2)}',
                'Algorithm ${sc['algo_version'] ?? ''} · processed in ${num1(sc['processing_ms'], 0)} ms',
              ].join('\n'),
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ]);
  }
}

/// Compare any two good-quality scans (reference -> test) with the PRD formulas.
class CompareScreen extends StatefulWidget {
  final String? testScanId;
  const CompareScreen({super.key, this.testScanId});
  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  late Future<List<Map<String, dynamic>>> _f = Api.scans();
  String? _ref, _test;
  Map<String, dynamic>? _result;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _test = widget.testScanId;
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final r = await Api.compare(_ref!, _test!);
      if (mounted) setState(() => _result = r);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(List<Map<String, dynamic>> good, bool reference) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (c, sc) => ListView(
            controller: sc,
            padding: const EdgeInsets.all(12),
            children: [
              Text(
                  reference
                      ? 'Reference scan (before)'
                      : 'Scan to compare (after)',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final s in good)
                ScanTile(
                    scan: s,
                    onTap: () => Navigator.pop(c, s['scan_id'] as String)),
            ]),
      ),
    );
    if (id == null) return;
    setState(() {
      if (reference) {
        _ref = id;
      } else {
        _test = id;
      }
      _result = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compare scans')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done)
            return const LoadingView();
          if (s.hasError)
            return ErrorView(
                error: s.error!,
                onRetry: () => setState(() => _f = Api.scans()));
          final good = s.data!.where((x) => x['sqi_passed'] == true).toList();
          Map<String, dynamic>? byId(String? id) {
            for (final x in good) {
              if (x['scan_id'] == id) return x;
            }
            return null;
          }

          if (_ref == null && good.isNotEmpty) {
            final base = good
                .where((x) =>
                    x['tag_event'] == 'Baseline' && x['scan_id'] != _test)
                .toList();
            if (base.isNotEmpty) _ref = base.first['scan_id'] as String;
          }
          if (good.length < 2) {
            return const EmptyView(
                icon: Icons.compare_arrows,
                title: 'Not enough scans',
                text: 'You need at least two good-quality scans to compare.');
          }
          final ref = byId(_ref), test = byId(_test);
          return ListView(padding: const EdgeInsets.all(16), children: [
            const Text(
                'Pick a reference (usually a baseline) and a later scan. The app computes the change in vascular '
                'tone and HRV between them.'),
            const SizedBox(height: 16),
            Text('Reference (before)',
                style: Theme.of(context).textTheme.labelLarge),
            ref == null
                ? OutlinedButton(
                    onPressed: () => _pick(good, true),
                    child: const Text('Choose reference scan'))
                : ScanTile(
                    scan: ref,
                    onTap: () => _pick(good, true),
                    trailing: const Icon(Icons.edit)),
            const Center(child: Icon(Icons.arrow_downward)),
            Text('Compare (after)',
                style: Theme.of(context).textTheme.labelLarge),
            test == null
                ? OutlinedButton(
                    onPressed: () => _pick(good, false),
                    child: const Text('Choose scan to compare'))
                : ScanTile(
                    scan: test,
                    onTap: () => _pick(good, false),
                    trailing: const Icon(Icons.edit)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || ref == null || test == null || _ref == _test
                  ? null
                  : _run,
              child: Text(_busy ? 'Comparing…' : 'Compare'),
            ),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: InfoBanner(tone: CaptureStatus.fail, text: _error!)),
            if (_result != null) ...[
              const SizedBox(height: 16),
              SectionCard(child: ComparisonCard(comparison: _result!)),
            ],
          ]);
        },
      ),
    );
  }
}
