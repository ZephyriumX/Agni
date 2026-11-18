import 'package:flutter/material.dart';

import 'api.dart';
import 'format.dart';
import 'scan_detail_screen.dart';
import 'widgets.dart';

/// Every scan on the account, newest first, grouped by day, filterable by type.
class HistoryScreen extends StatefulWidget {
  final VoidCallback? onStartScan;
  const HistoryScreen({super.key, this.onStartScan});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String? _tag;
  bool _goodOnly = false;
  late Future<List<Map<String, dynamic>>> _f = Api.scans();

  void _reload() => setState(() => _f = Api.scans());

  Future<void> _open(Map<String, dynamic> s) async {
    final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => ScanDetailScreen(scanId: s['scan_id'] as String)));
    if (changed == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('History'), actions: [
        IconButton(
          tooltip: 'Compare two scans',
          icon: const Icon(Icons.compare_arrows),
          onPressed: () => Navigator.push<void>(context,
              MaterialPageRoute(builder: (_) => const CompareScreen())),
        ),
        IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _reload),
      ]),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done)
            return const LoadingView();
          if (s.hasError) return ErrorView(error: s.error!, onRetry: _reload);
          final all = s.data!;
          if (all.isEmpty) {
            return ListView(children: [
              EmptyView(
                icon: Icons.history,
                title: 'No scans yet',
                text:
                    'Every scan you take is saved to your account and listed here, on any phone you sign in on.',
                action: widget.onStartScan == null
                    ? null
                    : FilledButton.icon(
                        onPressed: widget.onStartScan,
                        icon: const Icon(Icons.favorite),
                        label: const Text('Start a scan')),
              ),
            ]);
          }
          final tags = {for (final x in all) x['tag_event'] as String};
          final rows = all
              .where((x) =>
                  (_tag == null || x['tag_event'] == _tag) &&
                  (!_goodOnly || x['sqi_passed'] == true))
              .toList();
          final groups = <String, List<Map<String, dynamic>>>{};
          for (final r in rows) {
            final t = parseTs(r['timestamp']);
            groups.putIfAbsent(t == null ? '—' : fmtDay(t), () => []).add(r);
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                children: [
                  SizedBox(
                    height: 48,
                    child:
                        ListView(scrollDirection: Axis.horizontal, children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                            label: const Text('All'),
                            selected: _tag == null,
                            onSelected: (_) => setState(() => _tag = null)),
                      ),
                      for (final t in scanTags.where(tags.contains))
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                              label: Text(tagLabel(t)),
                              selected: _tag == t,
                              onSelected: (_) => setState(() => _tag = t)),
                        ),
                    ]),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text(
                        'Only good-quality scans (${rows.length} shown of ${all.length})'),
                    value: _goodOnly,
                    onChanged: (v) => setState(() => _goodOnly = v),
                  ),
                  for (final e in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                      child: Text(e.key,
                          style: Theme.of(context).textTheme.titleSmall),
                    ),
                    for (final r in e.value)
                      ScanTile(scan: r, onTap: () => _open(r)),
                  ],
                ]),
          );
        },
      ),
    );
  }
}

class ScanTile extends StatelessWidget {
  final Map<String, dynamic> scan;
  final VoidCallback? onTap;
  final Widget? trailing;
  const ScanTile({super.key, required this.scan, this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = scan['sqi_passed'] == true;
    final tag = scan['tag_event'] as String?;
    final t = parseTs(scan['timestamp']);
    final extra = [
      if (scan['meal_name'] != null) '${scan['meal_name']}',
      if (scan['intervention'] != null) '${scan['intervention']}',
      ...((scan['context_tags'] as List?) ?? const <dynamic>[])
          .map((e) => '$e'),
    ];
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: cs.surfaceContainerHighest.withAlpha(90),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: tagColor(tag).withAlpha(40),
          child: Icon(tagIcon(tag), color: tagColor(tag)),
        ),
        title: Row(children: [
          Expanded(
              child: Text(tagLabel(tag),
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(t == null ? '' : fmtTime(t),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ]),
        subtitle:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (extra.isNotEmpty)
            Text(extra.join(' · '),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            ok
                ? 'HRV ${num1(scan['rmssd'], 0)} ms · ${num1(scan['avg_bpm'], 0)} bpm · b/a ${num1(scan['ba_ratio'], 2)}'
                : 'Not analysed: signal quality too low',
            style: TextStyle(color: ok ? null : cs.error),
          ),
        ]),
        trailing: trailing ??
            (ok
                ? const Icon(Icons.chevron_right)
                : Icon(Icons.error_outline, color: cs.error)),
      ),
    );
  }
}
