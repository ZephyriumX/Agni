import 'package:flutter/material.dart';

import 'api.dart';
import 'capture_validation.dart';
import 'format.dart';
import 'pending_queue.dart';
import 'scan_detail_screen.dart';
import 'scan_screen.dart';
import 'session.dart';
import 'timer_screen.dart';
import 'widgets.dart';

/// Dashboard: greeting, baseline progress, quick scan actions, latest insights and the last scan vs baseline.
class HomeScreen extends StatefulWidget {
  final void Function(int tab) onOpenTab;
  final VoidCallback onDataChanged;
  const HomeScreen(
      {super.key, required this.onOpenTab, required this.onDataChanged});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loading = true;
  String? _error;
  int _pending = 0;
  Map<String, dynamic>? _a; // analytics (30 days)
  Map<String, dynamic>? _last; // most recent scan

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    var pending = await PendingQueue.count();
    try {
      if (pending > 0) {
        await PendingQueue.flush();
        pending = await PendingQueue.count();
      }
      final r = await Future.wait<Object>(
          [Api.analytics(days: 30), Api.scans(limit: 1)]);
      _a = r[0] as Map<String, dynamic>;
      final scans = r[1] as List<Map<String, dynamic>>;
      _last = scans.isEmpty ? null : scans.first;
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _pending = pending;
    });
  }

  Future<void> _scan(String tag, {String? intervention}) async {
    final r = await Navigator.push<Object?>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                ScanScreen(initialTag: tag, intervention: intervention)));
    if (r is Map && r['vajrasana_for'] != null && mounted) {
      await Navigator.push<void>(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  TimerScreen(preScanId: r['vajrasana_for'] as String)));
    }
    widget.onDataChanged();
    _refresh();
  }

  /// Guided practice: scan before -> 10-minute Vajrasana -> scan after (paired comparison).
  Future<void> _guidedVajrasana() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Guided Vajrasana'),
        content: const Text(
            '1. A short scan now (before).\n2. 10 minutes of Vajrasana with a timer.\n3. A scan right '
            'after.\n\nThe app then shows how your pulse changed with the practice.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Start')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final r = await Navigator.push<Object?>(
        context,
        MaterialPageRoute(
            builder: (_) => const ScanScreen(initialTag: 'Pre-Yoga')));
    if (r is Map && r['scan_id'] != null && mounted) {
      final passed = (r['sqi'] as Map?)?['passed'] == true;
      if (passed) {
        await Navigator.push<void>(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    TimerScreen(preScanId: r['scan_id'] as String)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'The "before" scan did not pass the quality check. Please try again.')));
      }
    }
    widget.onDataChanged();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = Session.instance;
    final hour = DateTime.now().hour;
    final greet = hour < 12
        ? 'Good morning'
        : hour < 17
            ? 'Good afternoon'
            : 'Good evening';
    final base = Map<String, dynamic>.from(
        (_a?['baseline'] ?? const <String, dynamic>{}) as Map);
    final nBase = (base['n'] as num?)?.toInt() ?? 0;
    final insights = ((_a?['insights'] as List?) ?? const <dynamic>[])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((i) => i['kind'] != 'prakriti')
        .take(2)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Icon(Icons.local_fire_department, color: cs.primary),
          const SizedBox(width: 8),
          const Text('Agni-Pulse'),
        ]),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _refresh),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => widget.onOpenTab(4),
              child: CircleAvatar(
                radius: 17,
                backgroundColor: cs.primaryContainer,
                child: Text(
                    s.displayName.isEmpty
                        ? '?'
                        : s.displayName[0].toUpperCase(),
                    style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              Text('$greet, ${s.displayName}',
                  style:
                      tt.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              if (s.prakriti != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('${s.prakriti} constitution',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                ),
              const SizedBox(height: 12),
              if (_error != null)
                InfoBanner(
                  tone: CaptureStatus.fail,
                  icon: Icons.cloud_off,
                  text: _error!,
                  action: TextButton(
                      onPressed: _refresh, child: const Text('Retry')),
                ),
              if (_pending > 0)
                InfoBanner(
                  tone: CaptureStatus.warning,
                  icon: Icons.cloud_upload_outlined,
                  text:
                      '$_pending scan(s) saved on this phone, waiting to upload.',
                  action: TextButton(
                      onPressed: _refresh, child: const Text('Upload now')),
                ),
              _hero(cs, tt, nBase),
              const SizedBox(height: 14),
              _quickActions(),
              if (_loading && _a == null)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator())),
              if (insights.isNotEmpty) ...[
                SectionHeader('Latest insights',
                    trailing: TextButton(
                        onPressed: () => widget.onOpenTab(1),
                        child: const Text('See all'))),
                for (final i in insights) _miniInsight(i),
              ],
              if (_last != null) ...[
                SectionHeader('Last scan',
                    trailing: TextButton(
                        onPressed: () => widget.onOpenTab(2),
                        child: const Text('History'))),
                _lastScan(_last!, base),
              ],
              const SizedBox(height: 16),
              Text('Wellness tool, not a medical device.',
                  textAlign: TextAlign.center,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
      ),
    );
  }

  Widget _hero(ColorScheme cs, TextTheme tt, int nBase) {
    final needBase = nBase < 3;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primary, cs.tertiary]),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(needBase ? 'Build your baseline' : 'Check your pulse',
            style: tt.headlineSmall
                ?.copyWith(color: cs.onPrimary, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
            needBase
                ? '$nBase of 3 baseline scans done. Rested, seated, ideally in the morning before food or coffee.'
                : 'Your normal range is set. Scan after meals and practices to see how they affect you.',
            style: tt.bodyMedium
                ?.copyWith(color: cs.onPrimary.withAlpha(235), height: 1.35)),
        if (needBase) ...[
          const SizedBox(height: 10),
          Row(children: [
            for (var i = 0; i < 3; i++)
              Expanded(
                child: Container(
                  height: 6,
                  margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                  decoration: BoxDecoration(
                      color:
                          i < nBase ? cs.onPrimary : cs.onPrimary.withAlpha(70),
                      borderRadius: BorderRadius.circular(3)),
                ),
              ),
          ]),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: cs.onPrimary, foregroundColor: cs.primary),
          icon: const Icon(Icons.favorite),
          label: Text(needBase ? 'Baseline scan' : 'Start scan'),
          onPressed: () => _scan('Baseline'),
        ),
      ]),
    );
  }

  Widget _quickActions() {
    Widget tile(IconData icon, String title, String sub, VoidCallback onTap) =>
        Expanded(
          child: Card(
            elevation: 0,
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withAlpha(110),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 8),
                      Text(title,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(sub,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ]),
              ),
            ),
          ),
        );
    return Column(children: [
      Row(children: [
        tile(Icons.restaurant, 'After a meal', '30-60 min after eating',
            () => _scan('Post-Meal')),
        tile(Icons.self_improvement, 'After a practice',
            'breathing, yoga, walk', () => _scan('Post-Intervention')),
      ]),
      Row(children: [
        tile(Icons.timer_outlined, 'Guided Vajrasana', 'scan · 10 min · scan',
            _guidedVajrasana),
        tile(Icons.compare_arrows, 'Compare scans', 'any two scans', () {
          Navigator.push<void>(context,
              MaterialPageRoute(builder: (_) => const CompareScreen()));
        }),
      ]),
    ]);
  }

  Widget _miniInsight(Map<String, dynamic> i) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (i['tone']) {
      'good' => Colors.green,
      'warn' => Colors.orange,
      'action' => cs.primary,
      _ => cs.tertiary,
    };
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: color.withAlpha(20),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: color.withAlpha(80))),
      child: ListTile(
        onTap: () => widget.onOpenTab(1),
        leading: Icon(
            i['tone'] == 'warn' ? Icons.error_outline : Icons.lightbulb_outline,
            color: color),
        title: Text('${i['title']}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle:
            Text('${i['body']}', maxLines: 3, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _lastScan(Map<String, dynamic> sc, Map<String, dynamic> base) {
    final ok = sc['sqi_passed'] == true;
    final t = parseTs(sc['timestamp']);
    final bm = Map<String, dynamic>.from(
        (base['metrics'] ?? const <String, dynamic>{}) as Map);
    String vs(String k, int d) {
      final b = (bm[k] as Map?)?['mean'] as num?;
      final v = sc[k] as num?;
      if (b == null || v == null || sc['tag_event'] == 'Baseline') return '';
      return 'baseline ${b.toStringAsFixed(d)}';
    }

    return SectionCard(
      title:
          '${tagLabel(sc['tag_event'] as String?)}${sc['meal_name'] != null ? ' · ${sc['meal_name']}' : ''}',
      icon: tagIcon(sc['tag_event'] as String?),
      trailing: StatusPill(
          status: ok ? CaptureStatus.pass : CaptureStatus.fail,
          label: ok ? 'Good' : 'Rejected'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (t != null)
          Text('${fmtDay(t)}, ${fmtTime(t)}',
              style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 10),
        if (ok)
          Wrap(spacing: 10, runSpacing: 10, children: [
            MetricTile(
                label: 'HRV',
                value: num1(sc['rmssd'], 0),
                unit: 'ms',
                hint: vs('rmssd', 0)),
            MetricTile(
                label: 'Heart rate',
                value: num1(sc['avg_bpm'], 0),
                unit: 'bpm',
                hint: vs('avg_bpm', 0)),
            MetricTile(
                label: 'b/a ratio',
                value: num1(sc['ba_ratio'], 2),
                hint: vs('ba_ratio', 2)),
          ])
        else
          const Text(
              'This scan did not pass the signal-quality check. Tips: rest your hand, cover lens and flash '
              'fully with light pressure, keep still.'),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () async {
              final changed = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          ScanDetailScreen(scanId: sc['scan_id'] as String)));
              if (changed == true) {
                widget.onDataChanged();
                _refresh();
              }
            },
            child: const Text('Details'),
          ),
        ),
      ]),
    );
  }
}
