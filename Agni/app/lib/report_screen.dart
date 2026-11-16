import 'package:flutter/material.dart';
import 'api.dart';
import 'result_view.dart';
import 'widgets.dart';
import 'capture_validation.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late Future<Map<String, dynamic>> _f = Api.report();
  String _n(dynamic v, [int d = 1]) => v == null ? '—' : (v as num).toStringAsFixed(d);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Metabolic report'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: () => setState(() => _f = Api.report())),
      ]),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (s.hasError) {
            return ListView(padding: const EdgeInsets.all(16), children: [
              SelectableText('${s.error}'),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => setState(() => _f = Api.report()), child: const Text('Retry')),
            ]);
          }
          final d = s.data!;
          final comps = List<Map<String, dynamic>>.from((d['comparisons'] ?? []).map((e) => Map<String, dynamic>.from(e)));
          final scans = List<Map<String, dynamic>>.from((d['scans'] ?? []).map((e) => Map<String, dynamic>.from(e)));
          final byId = {for (final x in scans) x['scan_id']: x};
          if (scans.isEmpty) {
            return const Padding(
                padding: EdgeInsets.all(16),
                child: InfoBanner(
                    icon: Icons.favorite_border,
                    text: 'No scans yet. Record a Baseline scan first (rested, seated, morning is ideal).'));
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (d['baseline_scan_id'] == null)
              const InfoBanner(
                  tone: CaptureStatus.warning, text: 'No good-quality Baseline yet. Comparisons need one.'),
            if (comps.isNotEmpty) Text('Comparisons', style: Theme.of(c).textTheme.titleMedium),
            for (final k in comps.reversed)
              SectionCard(
                title: '${byId[k['baseline_scan_id']]?['tag_event'] ?? '?'}  →  ${byId[k['test_scan_id']]?['tag_event'] ?? '?'}',
                icon: Icons.compare_arrows,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ComparisonCard(comparison: k),
                  TextButton(onPressed: () => _showBeforeAfter(context, k), child: const Text('Before / after graph')),
                ]),
              ),
            const Divider(height: 32),
            Text('Scan history', style: Theme.of(c).textTheme.titleMedium),
            for (final sc in scans.reversed)
              ListTile(
                dense: true,
                leading: Icon(sc['sqi_passed'] == true ? Icons.check_circle : Icons.error_outline,
                    color: sc['sqi_passed'] == true ? Colors.green : Colors.orange),
                title: Text('${sc['tag_event']}  ·  ${_n(sc['avg_bpm'], 0)} bpm'),
                subtitle: Text('b/a ${_n(sc['ba_ratio'], 2)}   RMSSD ${_n(sc['rmssd'])} ms\n${sc['timestamp']}'),
                isThreeLine: true,
              ),
            const SizedBox(height: 8),
            Text(d['disclaimer'] ?? '', style: Theme.of(c).textTheme.bodySmall),
          ]);
        },
      ),
    );
  }

  Future<void> _showBeforeAfter(BuildContext context, Map<String, dynamic> k) async {
    try {
      final b = await Api.scan(k['baseline_scan_id']);
      final a = await Api.scan(k['test_scan_id']);
      if (!context.mounted) return;
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: BeforeAfterCard(
            before: b['template'] == null ? null : Map<String, dynamic>.from(b['template']),
            after: a['template'] == null ? null : Map<String, dynamic>.from(a['template']),
          ),
        ),
      );
    } on ApiError catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
