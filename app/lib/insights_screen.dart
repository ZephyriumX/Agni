import 'package:flutter/material.dart';

import 'api.dart';
import 'capture_validation.dart';
import 'charts.dart';
import 'format.dart';
import 'scan_detail_screen.dart';
import 'widgets.dart';

typedef Json = Map<String, dynamic>;

Json _m(dynamic v) =>
    Map<String, dynamic>.from((v ?? const <String, dynamic>{}) as Map);
List<Json> _l(dynamic v) =>
    ((v ?? const <dynamic>[]) as List).map((e) => _m(e)).toList();
double? _d(dynamic v) => (v as num?)?.toDouble();

const _metricOrder = ['rmssd', 'ba_ratio', 'avg_bpm'];
const _metricDecimals = {'rmssd': 0, 'ba_ratio': 2, 'avg_bpm': 0};

/// Personal analytics: baseline range, trends, responses to meals / interventions / contexts, quality, insights.
class InsightsScreen extends StatefulWidget {
  final VoidCallback? onStartScan;
  const InsightsScreen({super.key, this.onStartScan});
  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  int _days = 30;
  late Future<Json> _f = Api.analytics(days: _days);
  String _metric = 'rmssd';

  void _reload() => setState(() => _f = Api.analytics(days: _days));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Insights'), actions: [
        IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'How to read this',
            onPressed: _help),
        IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _reload),
      ]),
      body: FutureBuilder<Json>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done)
            return const LoadingView(text: 'Analysing your history…');
          if (s.hasError) return ErrorView(error: s.error!, onRetry: _reload);
          return RefreshIndicator(
              onRefresh: () async => _reload(), child: _content(s.data!));
        },
      ),
    );
  }

  Widget _period() => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 7, label: Text('7 d')),
            ButtonSegment(value: 30, label: Text('30 d')),
            ButtonSegment(value: 90, label: Text('90 d')),
            ButtonSegment(value: 365, label: Text('1 yr')),
          ],
          selected: {_days},
          onSelectionChanged: (v) {
            _days = v.first;
            _reload();
          },
        ),
      );

  Widget _content(Json a) {
    final ov = _m(a['overview']);
    if ((ov['all_time_scans'] as num? ?? 0) == 0) {
      return ListView(children: [
        EmptyView(
          icon: Icons.insights,
          title: 'No scans yet',
          text:
              'Your insights appear here once you have scanned. Start with a baseline: sit quietly for two minutes, '
              'then scan.',
          action: widget.onStartScan == null
              ? null
              : FilledButton.icon(
                  onPressed: widget.onStartScan,
                  icon: const Icon(Icons.favorite),
                  label: const Text('Baseline scan')),
        ),
      ]);
    }
    final base = _m(a['baseline']);
    final insights = _l(a['insights']);
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          _period(),
          _overview(ov, base),
          if (insights.isNotEmpty) ...[
            const SectionHeader('Key insights',
                subtitle: 'Generated from your own scans'),
            for (final i in insights) _InsightCard(i),
          ],
          const SectionHeader('Your normal range',
              subtitle: 'From good-quality Baseline scans'),
          _baselineCard(base),
          const SectionHeader('Trends'),
          _trendCard(a, base),
          if (_l(a['responses']).isNotEmpty) ...[
            const SectionHeader('Scans vs your baseline',
                subtitle: 'Most recent first · tap for details'),
            _responses(_l(a['responses'])),
          ],
          if (_l(a['meals']).isNotEmpty ||
              _l(a['meal_descriptors']).isNotEmpty) ...[
            const SectionHeader('Meal responses',
                subtitle:
                    'HRV after a meal as % of your baseline (higher = calmer)'),
            _meals(a),
          ],
          if (_l(a['interventions']).isNotEmpty) ...[
            const SectionHeader('Interventions',
                subtitle: 'Effect of breathing, yoga and other practices'),
            for (final iv in _l(a['interventions'])) _intervention(iv),
          ],
          if (_l(a['contexts']).isNotEmpty || _l(a['by_tag']).isNotEmpty) ...[
            const SectionHeader('Situations',
                subtitle: 'Average response by scan type and context'),
            _situations(a),
          ],
          if (_l(a['time_of_day']).length > 1) ...[
            const SectionHeader('Time of day'),
            _timeOfDay(_l(a['time_of_day'])),
          ],
          const SectionHeader('Signal quality'),
          _quality(_m(a['quality']), ov),
          if (a['prakriti'] != null) ...[
            const SectionHeader('Personal guidance'),
            _prakriti(_m(a['prakriti'])),
          ],
          const SizedBox(height: 12),
          _method(_m(a['method'])),
        ]);
  }

  // ---------------------------------------------------------------- overview
  Widget _overview(Json ov, Json base) {
    final q = _d(ov['quality_rate']);
    final n = (base['n'] as num?)?.toInt() ?? 0;
    return Wrap(spacing: 10, runSpacing: 10, children: [
      MetricTile(
          label: 'Good scans',
          value: '${ov['good_scans'] ?? 0}',
          hint: 'of ${ov['total_scans'] ?? 0} in period'),
      MetricTile(
          label: 'Quality pass rate',
          value: q == null ? '—' : '${(q * 100).round()}',
          unit: '%'),
      MetricTile(
          label: 'Baselines',
          value: '$n',
          hint:
              n >= 3 ? '${base['reliability']}' : '${3 - n} more recommended'),
      MetricTile(
          label: 'Streak',
          value: '${ov['streak_days'] ?? 0}',
          unit: 'days',
          hint: '${ov['days_active']} active days'),
    ]);
  }

  // ---------------------------------------------------------------- baseline
  Widget _baselineCard(Json base) {
    final n = (base['n'] as num?)?.toInt() ?? 0;
    final metrics = _m(base['metrics']);
    final info = const {
      'rmssd': ('HRV (RMSSD)', 'ms'),
      'ba_ratio': ('b/a ratio', ''),
      'avg_bpm': ('Heart rate', 'bpm')
    };
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (n == 0)
          const InfoBanner(
              tone: CaptureStatus.warning,
              text:
                  'No good-quality baseline yet. Comparisons and ranges appear after your first Baseline scan.')
        else ...[
          Row(children: [
            Expanded(
                child: Text(
                    '$n baseline scan${n == 1 ? '' : 's'} · ${base['scope'] ?? ''}')),
            _ReliabilityChip('${base['reliability']}'),
          ]),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: (n / 7).clamp(0.0, 1.0), minHeight: 6),
          ),
          const SizedBox(height: 4),
          Text(
              n < 3
                  ? 'Add ${3 - n} more on different days to estimate your normal range.'
                  : n < 7
                      ? 'Established. 7+ baselines make the range very reliable.'
                      : 'Strong: plenty of baselines.',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          for (final k in _metricOrder)
            if (metrics[k] != null)
              _rangeRow(info[k]!.$1, info[k]!.$2, _m(metrics[k]),
                  _metricDecimals[k]!),
        ],
      ]),
    );
  }

  Widget _rangeRow(String label, String unit, Json m, int dec) {
    final range = m['normal_range'] as List?;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
            flex: 4,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(
          flex: 4,
          child: Text(
              '${num1(m['mean'], dec)}${m['sd'] != null ? ' ± ${num1(m['sd'], dec == 0 ? 1 : dec)}' : ''} $unit'),
        ),
        Expanded(
          flex: 5,
          child: Text(
              range == null
                  ? 'range after 3 scans'
                  : 'normal ${num1(range[0], dec)} – ${num1(range[1], dec)}',
              textAlign: TextAlign.right,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- trends
  Widget _trendCard(Json a, Json base) {
    final series = _m(a['series']);
    final s = _m(series[_metric]);
    final info = _m(s['info']);
    final pts = _l(s['points']);
    final roll = _l(s['baseline_rolling']);
    final bm = _m(_m(base['metrics'])[_metric]);
    final range = bm['normal_range'] as List?;
    final trend = _m(s['trend']);
    final dec = _metricDecimals[_metric]!;
    final cs = Theme.of(context).colorScheme;
    String trendText() {
      if (trend['status'] != 'ok') {
        return 'Trend needs at least 4 baselines spread over 5+ days (you have ${trend['n'] ?? 0}).';
      }
      final per = signed(trend['per_week'], dec == 0 ? 1 : dec + 1,
          ' ${info['unit'] ?? ''}'.trimRight());
      if (trend['meaningful'] != true) {
        return 'Stable: baseline change of $per per week is within your normal variation.';
      }
      return trend['direction'] == 'better'
          ? 'Improving: $per per week across ${trend['n']} baselines (larger than your normal variation).'
          : 'Worsening: $per per week across ${trend['n']} baselines (larger than your normal variation).';
    }

    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, children: [
          for (final k in _metricOrder)
            ChoiceChip(
              label: Text(_m(_m(series[k])['info'])['label'] as String? ?? k),
              selected: _metric == k,
              onSelected: (_) => setState(() => _metric = k),
            ),
        ]),
        const SizedBox(height: 12),
        if (pts.isEmpty)
          const Padding(
              padding: EdgeInsets.all(24),
              child:
                  Center(child: Text('No good-quality scans in this period.')))
        else
          TrendChart(
            points: [
              for (final p in pts)
                if (parseTs(p['t']) != null && p['v'] != null)
                  ChartPoint(parseTs(p['t'])!, _d(p['v'])!,
                      tagColor(p['tag'] as String?),
                      emphasis: p['tag'] == 'Baseline'),
            ],
            line: [
              for (final p in roll)
                if (parseTs(p['t']) != null && p['v'] != null)
                  ChartPoint(parseTs(p['t'])!, _d(p['v'])!, cs.primary),
            ],
            bandLow: range == null ? null : _d(range[0]),
            bandHigh: range == null ? null : _d(range[1]),
            mean: _d(bm['mean']),
            decimals: dec,
          ),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 4, children: [
          _legendDot(tagColor('Baseline'), 'Baseline'),
          _legendDot(tagColor('Post-Meal'), 'After meal'),
          _legendDot(tagColor('Post-Intervention'), 'After practice'),
          _legendDot(tagColor('Other'), 'Other'),
          _legendBox(Colors.green.withAlpha(60), 'Your normal range'),
        ]),
        const Divider(height: 24),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
              trend['meaningful'] == true
                  ? (trend['direction'] == 'better'
                      ? Icons.trending_up
                      : Icons.trending_down)
                  : Icons.trending_flat,
              color: trend['meaningful'] == true
                  ? (trend['direction'] == 'better' ? Colors.green : cs.error)
                  : cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(trendText())),
        ]),
        const SizedBox(height: 8),
        Text('${info['explain'] ?? ''}',
            style: TextStyle(
                fontSize: 12, color: cs.onSurfaceVariant, height: 1.35)),
      ]),
    );
  }

  Widget _legendDot(Color c, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ]);

  Widget _legendBox(Color c, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 14, height: 10, color: c),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ]);

  // ---------------------------------------------------------------- responses
  Widget _responses(List<Json> rows) {
    final recent = rows.reversed.take(12).toList();
    return SectionCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(children: [
        for (final r in recent)
          InkWell(
            onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        ScanDetailScreen(scanId: r['scan_id'] as String))),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(tagIcon(r['tag'] as String?),
                          size: 18, color: tagColor(r['tag'] as String?)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            [
                              tagLabel(r['tag'] as String?),
                              if (r['meal'] != null) '${r['meal']}',
                              if (r['intervention'] != null)
                                '${r['intervention']}',
                            ].join(' · '),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis),
                      ),
                      Text(
                          parseTs(r['t']) == null
                              ? ''
                              : fmtDay(parseTs(r['t'])!),
                          style: const TextStyle(fontSize: 12)),
                    ]),
                    const SizedBox(height: 8),
                    _deltaRow('HRV', _m(r['rmssd']), 'ms', true, 0),
                    _deltaRow('Heart rate', _m(r['avg_bpm']), 'bpm', null, 0),
                    _deltaRow('b/a', _m(r['ba_ratio']), '', false, 2),
                  ]),
            ),
          ),
      ]),
    );
  }

  Widget _deltaRow(
      String label, Json m, String unit, bool? higherIsGood, int dec) {
    final diff = _d(m['diff']) ?? 0;
    final base = _d(m['baseline']) ?? 1;
    final level = m['level'] as String? ?? 'normal';
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(
            width: 74,
            child: Text(label, style: const TextStyle(fontSize: 12))),
        Expanded(
          child: DeltaBar(
            value: diff,
            scale: (base.abs() * (unit == 'bpm' ? 0.2 : 0.5))
                .clamp(0.05, 1e9)
                .toDouble(),
            positiveIsGood: higherIsGood ?? true,
            neutral: higherIsGood == null,
          ),
        ),
        SizedBox(
          width: 92,
          child: Text(
              ' ${signed(diff, dec == 0 ? 1 : dec, unit.isEmpty ? '' : ' $unit')}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12)),
        ),
        SizedBox(
          width: 62,
          child: Text(
            level == 'clear'
                ? 'clear'
                : level == 'possible'
                    ? 'possible'
                    : 'normal',
            textAlign: TextAlign.right,
            style: TextStyle(
                fontSize: 11,
                fontWeight:
                    level == 'clear' ? FontWeight.w700 : FontWeight.normal,
                color: level == 'normal' ? cs.onSurfaceVariant : cs.onSurface),
          ),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- meals
  Widget _meals(Json a) {
    final meals = _l(a['meals']);
    final desc = _l(a['meal_descriptors']);
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final m in meals) ...[
          Row(children: [
            Expanded(
                child: Text('${m['name']}',
                    style: const TextStyle(fontWeight: FontWeight.w600))),
            ConfidenceChip(
                level: m['confidence'] as String?,
                n: (m['n'] as num?)?.toInt()),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: PercentBar(value: _d(m['compatibility_pct']))),
            SizedBox(
                width: 52,
                child: Text(' ${pct(m['compatibility_pct'])}',
                    textAlign: TextAlign.right)),
          ]),
          const SizedBox(height: 2),
          Text(
              '${m['effect']} · heart rate ${signed(m['bpm_diff_mean'], 0, ' bpm')} · b/a ${signed(m['tone_pct_mean'], 0, '%')}'
              '${m['minutes_after_meal_median'] != null ? ' · scanned ~${num1(m['minutes_after_meal_median'], 0)} min after' : ''}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(height: 14),
        ],
        if (desc.isNotEmpty) ...[
          Text('By meal type', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final d in desc)
              Chip(
                avatar: Icon(
                    (_d(d['hrv_ratio_mean']) ?? 1) < 0.85
                        ? Icons.arrow_downward
                        : Icons.check,
                    size: 16,
                    color: (_d(d['hrv_ratio_mean']) ?? 1) < 0.85
                        ? cs.error
                        : Colors.green),
                label: Text(
                    '${capitalise('${d['descriptor']}')}: ${pct(d['compatibility_pct'])} (n=${d['n']})'),
              ),
          ]),
        ],
        const SizedBox(height: 6),
        Text(
            'The bar marks 70 %: below it the PRD rule calls the meal "incompatible" (HRV fell below 70 % of baseline).',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ]),
    );
  }

  // ---------------------------------------------------------------- interventions
  Widget _intervention(Json iv) {
    final imp = _d(iv['improvement_pct_mean']);
    final helped = (imp ?? 0) > 0;
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      title: '${iv['type']}',
      icon: Icons.self_improvement,
      trailing: ConfidenceChip(
          level: iv['confidence'] as String?, n: (iv['n'] as num?)?.toInt()),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 10, runSpacing: 10, children: [
          MetricTile(
              label: 'b/a improvement',
              value: imp == null ? '—' : signed(imp, 1),
              unit: '%',
              hint: 'positive = more elastic'),
          MetricTile(
              label: 'HRV after',
              value: _d(iv['hrv_ratio_mean']) == null
                  ? '—'
                  : '×${num1(iv['hrv_ratio_mean'], 2)}',
              hint: '>1 = calmer'),
          MetricTile(
              label: 'Sessions improved',
              value: '${iv['improved_count']}/${iv['n']}',
              hint: '${iv['paired']} paired'),
        ]),
        const SizedBox(height: 8),
        Text(
            helped
                ? 'On average this practice moved your pulse-wave shape in the healthier direction.'
                : 'No consistent benefit yet. Single sessions vary; keep testing.',
            style: TextStyle(
                color: helped ? Colors.green.shade700 : cs.onSurfaceVariant)),
        Text(
            '"Paired" = compared with a scan taken up to 2 h before the practice; otherwise with your baseline.',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ]),
    );
  }

  // ---------------------------------------------------------------- situations
  Widget _situations(Json a) {
    final byTag = _l(a['by_tag']);
    final ctx = _l(a['contexts']);
    final cs = Theme.of(context).colorScheme;
    Widget row(String label, Json g, {String? sub}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(sub ?? '${g['effect'] ?? ''}',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                  ]),
            ),
            SizedBox(
                width: 84,
                child: Text('HRV ${pct(g['compatibility_pct'])}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13))),
            SizedBox(
                width: 72,
                child: Align(
                    alignment: Alignment.centerRight,
                    child: ConfidenceChip(level: g['confidence'] as String?))),
          ]),
        );
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final g in byTag) row(tagLabel(g['tag'] as String?), g),
        if (ctx.isNotEmpty) const Divider(height: 20),
        for (final c in ctx)
          row('With ${c['context']}', _m(c['with']),
              sub:
                  'vs ${pct(_m(c['without'])['compatibility_pct'])} without · ${c['effect']}'),
        const SizedBox(height: 4),
        Text(
            'HRV % = HRV after, as a share of your baseline average. 100 % or more = as calm as your baseline.',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ]),
    );
  }

  Widget _timeOfDay(List<Json> rows) => SectionCard(
        child: Table(
          columnWidths: const {
            0: FlexColumnWidth(3),
            1: FlexColumnWidth(2),
            2: FlexColumnWidth(2),
            3: FlexColumnWidth(2)
          },
          children: [
            const TableRow(children: [
              Text('', style: TextStyle(fontSize: 12)),
              Text('HRV', style: TextStyle(fontWeight: FontWeight.w600)),
              Text('HR', style: TextStyle(fontWeight: FontWeight.w600)),
              Text('b/a', style: TextStyle(fontWeight: FontWeight.w600)),
            ]),
            for (final r in rows)
              TableRow(children: [
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text('${capitalise('${r['part']}')} (n=${r['n']})')),
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text('${num1(r['rmssd'], 0)} ms')),
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(num1(r['avg_bpm'], 0))),
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(num1(r['ba_ratio'], 2))),
              ]),
          ],
        ),
      );

  // ---------------------------------------------------------------- quality
  Widget _quality(Json q, Json ov) {
    final reasons = _l(q['top_reasons']);
    final rate = _d(q['pass_rate']);
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          StatusPill(
            status: rate == null
                ? null
                : rate >= 0.8
                    ? CaptureStatus.pass
                    : rate >= 0.6
                        ? CaptureStatus.warning
                        : CaptureStatus.fail,
            label:
                rate == null ? 'No scans' : '${(rate * 100).round()}% passed',
          ),
          const Spacer(),
          Text(q['mean_fps'] == null ? '' : 'avg ${num1(q['mean_fps'])} fps',
              style: const TextStyle(fontSize: 12)),
        ]),
        const SizedBox(height: 10),
        if (reasons.isEmpty)
          const Text('No failed scans in this period.')
        else ...[
          const Text('Most common reasons a scan was rejected:'),
          for (final r in reasons)
            Text('• ${r['reason']} (${r['count']}×)',
                style: const TextStyle(fontSize: 13)),
        ],
        const SizedBox(height: 8),
        Text(
            'Only scans that pass both the camera-timing and the signal-quality checks are used in any number on this '
            'page. Failed scans are counted here but never analysed.',
            style: TextStyle(
                fontSize: 12, color: cs.onSurfaceVariant, height: 1.35)),
      ]),
    );
  }

  Widget _prakriti(Json p) {
    final g = _m(p['guidance']);
    return SectionCard(
      title: '${p['type']} constitution',
      icon: Icons.spa,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final e in g.entries) ...[
          Text('${e.key}: ${_m(e.value)['focus']}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Meals: ${_m(e.value)['meals']}'),
          Text('Routine: ${_m(e.value)['routine']}'),
          Text('Watch in your scans: ${_m(e.value)['watch']}'),
          const SizedBox(height: 10),
        ],
        Text('${p['note'] ?? ''}',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }

  Widget _method(Json m) => Text(
        'Method: baseline = ${m['baseline'] ?? ''}. Significance: ${m['significance'] ?? ''}. '
        'Confidence: ${m['confidence'] ?? ''}. ${m['limits'] ?? ''}',
        style: Theme.of(context).textTheme.bodySmall,
      );

  void _help() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.8,
          builder: (c, sc) => ListView(
              controller: sc,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              children: const [
                Text('How to read your insights',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                SizedBox(height: 16),
                _HelpItem(
                    'HRV (RMSSD)',
                    'How much the time between heartbeats varies. Higher usually means a calmer, recovered nervous system. It '
                        'drops with stress, caffeine, heavy meals, alcohol and poor sleep.'),
                _HelpItem(
                    'b/a ratio',
                    'From the second derivative of the pulse wave. More negative usually means more elastic arteries; values '
                        'moving toward zero suggest higher vascular tone. Experimental indicator.'),
                _HelpItem('Heart rate',
                    'Beats per minute during the scan. Rises after meals, exercise, caffeine and stress.'),
                _HelpItem(
                    'Your normal range',
                    'The average ± one standard deviation of your Baseline scans. About two out of three relaxed scans '
                        'should fall inside it. It needs at least 3 baselines.'),
                _HelpItem(
                    'clear / possible / normal',
                    'A reading 2× your usual spread away from your baseline is a "clear" change, 1× is "possible", '
                        'otherwise it is within your normal variation.'),
                _HelpItem(
                    'Confidence',
                    'Based on how many scans support a finding: 1 = low, 2-3 = medium, 4+ = high. Repeat a meal or practice '
                        'a few times before trusting a pattern.'),
                _HelpItem(
                    'HRV % after a meal',
                    'Your HRV after the meal as a share of your baseline average. Below 70 % follows the PRD definition of an '
                        '"incompatible" meal.'),
                _HelpItem(
                    'Limits',
                    'Smartphone PPG is a wellness measurement, not a diagnosis, and has not been clinically validated here. '
                        'Motion, finger pressure, cold hands and light all affect it.'),
              ]),
        ),
      );
}

class _HelpItem extends StatelessWidget {
  final String title, body;
  const _HelpItem(this.title, this.body);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 3),
          Text(body, style: const TextStyle(height: 1.4)),
        ]),
      );
}

class _ReliabilityChip extends StatelessWidget {
  final String level;
  const _ReliabilityChip(this.level);
  @override
  Widget build(BuildContext context) {
    final status = switch (level) {
      'strong' || 'established' => CaptureStatus.pass,
      'preliminary' => CaptureStatus.warning,
      _ => null,
    };
    return StatusPill(status: status, label: capitalise(level));
  }
}

class _InsightCard extends StatelessWidget {
  final Json i;
  const _InsightCard(this.i);
  @override
  Widget build(BuildContext context) {
    final tone = i['tone'] as String?;
    final cs = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (tone) {
      'good' => (Icons.thumb_up_alt_outlined, Colors.green),
      'warn' => (Icons.error_outline, Colors.orange),
      'action' => (Icons.flag_outlined, cs.primary),
      _ => (Icons.lightbulb_outline, cs.tertiary),
    };
    final kindIcon = switch (i['kind']) {
      'meal' => Icons.restaurant,
      'intervention' => Icons.self_improvement,
      'trend' => Icons.show_chart,
      'context' => Icons.local_cafe_outlined,
      'pattern' => Icons.schedule,
      'quality' => Icons.sensors,
      'prakriti' => Icons.spa,
      'habit' => Icons.local_fire_department,
      _ => icon,
    };
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: color.withAlpha(90))),
      color: color.withAlpha(18),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(
              radius: 18,
              backgroundColor: color.withAlpha(40),
              child: Icon(kindIcon, color: color, size: 20)),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${i['title']}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 4),
              Text('${i['body']}', style: const TextStyle(height: 1.35)),
              const SizedBox(height: 6),
              if (i['kind'] != 'action' && i['kind'] != 'prakriti')
                ConfidenceChip(
                    level: i['confidence'] as String?,
                    n: (i['evidence_n'] as num?)?.toInt()),
              if (i['note'] != null)
                Text('${i['note']}',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }
}
