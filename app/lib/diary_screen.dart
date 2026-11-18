import 'package:flutter/material.dart';

import 'api.dart';
import 'capture_validation.dart';
import 'charts.dart';
import 'format.dart';
import 'scan_screen.dart';
import 'widgets.dart';

typedef _DiaryData = (
  List<Map<String, dynamic>>,
  Map<String, dynamic>,
  List<Map<String, dynamic>>
);

/// Food diary: log meals, scan after them, and see which meals suit you (PRD F8, personal ranking).
class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});
  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  late Future<_DiaryData> _f = _load();

  Future<_DiaryData> _load() async {
    final r = await Future.wait<Object>(
        [Api.meals(), Api.analytics(days: 365), Api.scans(tag: 'Post-Meal')]);
    return (
      r[0] as List<Map<String, dynamic>>,
      r[1] as Map<String, dynamic>,
      r[2] as List<Map<String, dynamic>>
    );
  }

  void _reload() => setState(() => _f = _load());

  Future<void> _log() async {
    final meal = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const MealForm(),
    );
    if (meal == null || !mounted) return;
    _reload();
    final scanNow = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('"${meal['name']}" logged'),
        content: const Text(
            'For a comparable reading, scan about 30-60 minutes after eating. You can pick this meal on '
            'the scan screen (After meal), or from its menu here.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Later')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Scan now')),
        ],
      ),
    );
    if (scanNow == true && mounted) {
      await Navigator.push<Object?>(
          context,
          MaterialPageRoute(
              builder: (_) => ScanScreen(
                  initialTag: 'Post-Meal',
                  mealId: meal['meal_id'] as String?)));
      _reload();
    }
  }

  Future<void> _delete(Map<String, dynamic> m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "${m['name']}"?'),
        content: const Text(
            'Scans taken after it are kept but no longer linked to this meal.'),
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
      await Api.deleteMeal(m['meal_id'] as String);
      _reload();
    } on ApiError catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Food diary'), actions: [
        IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _reload),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'log-meal',
        onPressed: _log,
        icon: const Icon(Icons.add),
        label: const Text('Log meal'),
      ),
      body: FutureBuilder<_DiaryData>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done)
            return const LoadingView();
          if (s.hasError) return ErrorView(error: s.error!, onRetry: _reload);
          final (meals, a, postMeal) = s.data!;
          final ranked = ((a['meals'] as List?) ?? const <dynamic>[])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          final scannedMeals = <dynamic>{
            for (final x in postMeal)
              if (x['sqi_passed'] == true && x['meal_id'] != null) x['meal_id'],
          };
          final hasBaseline =
              (((a['baseline'] as Map?)?['n'] as num?) ?? 0) > 0;
          if (meals.isEmpty) {
            return ListView(children: [
              EmptyView(
                icon: Icons.restaurant,
                title: 'Your food diary is empty',
                text:
                    'Log what you eat, then scan 30-60 minutes later. Over time the app ranks meals by how calm your '
                    'pulse stays afterwards.',
                action: FilledButton.icon(
                    onPressed: _log,
                    icon: const Icon(Icons.add),
                    label: const Text('Log a meal')),
              ),
            ]);
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                children: [
                  if (!hasBaseline)
                    const InfoBanner(
                        tone: CaptureStatus.warning,
                        text:
                            'Meal scores need a baseline scan to compare against. Record one when rested.'),
                  if (ranked.isNotEmpty) ...[
                    const SectionHeader('Meals ranked for you',
                        subtitle: 'HRV after the meal as % of your baseline'),
                    SectionCard(
                      child: Column(children: [
                        for (var i = 0; i < ranked.length; i++)
                          _rankRow(i + 1, ranked[i]),
                        const SizedBox(height: 4),
                        Text(
                            '70 % mark = PRD threshold. Below it, HRV fell enough to call the meal "incompatible". '
                            'Wellness estimate only.',
                            style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                      ]),
                    ),
                  ],
                  const SectionHeader('Recent meals'),
                  for (final m in meals)
                    _mealTile(m, scannedMeals.contains(m['meal_id'])),
                ]),
          );
        },
      ),
    );
  }

  Widget _rankRow(int rank, Map<String, dynamic> m) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          CircleAvatar(
              radius: 14,
              child: Text('$rank', style: const TextStyle(fontSize: 12))),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text('${m['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                Text(pct(m['compatibility_pct'])),
              ]),
              const SizedBox(height: 4),
              PercentBar(value: (m['compatibility_pct'] as num?)?.toDouble()),
              const SizedBox(height: 2),
              Row(children: [
                Expanded(
                    child: Text('${m['effect']}',
                        style: const TextStyle(fontSize: 12))),
                ConfidenceChip(
                    level: m['confidence'] as String?,
                    n: (m['n'] as num?)?.toInt()),
              ]),
            ]),
          ),
        ]),
      );

  Widget _mealTile(Map<String, dynamic> m, bool scanned) {
    final t = parseTs(m['eaten_at']);
    final desc = ((m['descriptors'] as List?) ?? const <dynamic>[])
        .map((e) => '$e')
        .toList();
    final cs = Theme.of(context).colorScheme;
    final recent = t != null && DateTime.now().difference(t).inHours < 6;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: cs.surfaceContainerHighest.withAlpha(90),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: CircleAvatar(
            backgroundColor: cs.primaryContainer,
            child:
                Icon(Icons.restaurant, color: cs.onPrimaryContainer, size: 20)),
        title: Text('${m['name']}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text([
          if (t != null) '${fmtDay(t)} ${fmtTime(t)}',
          if (m['meal_type'] != null) capitalise('${m['meal_type']}'),
          ...desc,
          if (scanned) 'scanned' else if (recent) 'scan pending',
        ].join(' · ')),
        trailing: PopupMenuButton<String>(
          tooltip: 'Meal options',
          onSelected: (v) async {
            if (v == 'scan') {
              await Navigator.push<Object?>(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ScanScreen(
                          initialTag: 'Post-Meal',
                          mealId: m['meal_id'] as String?)));
              _reload();
            } else if (v == 'delete') {
              await _delete(m);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'scan', child: Text('Scan after this meal')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: scanned
                ? const Icon(Icons.check_circle, color: Colors.green)
                : Icon(recent ? Icons.schedule : Icons.more_vert,
                    color: recent ? cs.primary : null),
          ),
        ),
      ),
    );
  }
}

/// Bottom-sheet form; pops with the created meal.
class MealForm extends StatefulWidget {
  const MealForm({super.key});
  @override
  State<MealForm> createState() => _MealFormState();
}

class _MealFormState extends State<MealForm> {
  final _name = TextEditingController();
  final _notes = TextEditingController();
  String? _type = guessMealType();
  final Set<String> _desc = {};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'What did you eat?');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final m = await Api.createMeal(_name.text.trim(),
          mealType: _type, descriptors: _desc.toList(), notes: _notes.text);
      if (mounted) Navigator.pop(context, m);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Log a meal',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 14),
                TextField(
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                      labelText: 'What did you eat?',
                      hintText: 'e.g. Poha with peanuts'),
                ),
                const SizedBox(height: 14),
                MealDetailsPicker(
                    type: _type,
                    descriptors: _desc,
                    onType: (v) => setState(() => _type = v),
                    onChanged: () => setState(() {})),
                const SizedBox(height: 10),
                TextField(
                    controller: _notes,
                    decoration:
                        const InputDecoration(labelText: 'Notes (optional)')),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child:
                          InfoBanner(tone: CaptureStatus.fail, text: _error!)),
                const SizedBox(height: 14),
                FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(_busy ? 'Saving…' : 'Save meal')),
              ]),
        ),
      );
}

String guessMealType() {
  final h = DateTime.now().hour;
  return h < 11
      ? 'breakfast'
      : h < 16
          ? 'lunch'
          : h < 19
              ? 'snack'
              : 'dinner';
}

/// Meal type + descriptor chips (shared by the diary form and the scan screen).
class MealDetailsPicker extends StatelessWidget {
  final String? type;
  final Set<String> descriptors;
  final ValueChanged<String?> onType;
  final VoidCallback onChanged;
  const MealDetailsPicker(
      {super.key,
      required this.type,
      required this.descriptors,
      required this.onType,
      required this.onChanged});

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in mealTypes)
            ChoiceChip(
                label: Text(capitalise(t)),
                selected: type == t,
                onSelected: (s) => onType(s ? t : null)),
        ]),
        const SizedBox(height: 10),
        Text('Describe it (helps find patterns)',
            style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final d in mealDescriptors)
            FilterChip(
              label: Text(d),
              selected: descriptors.contains(d),
              onSelected: (s) {
                if (s) {
                  descriptors.add(d);
                } else {
                  descriptors.remove(d);
                }
                onChanged();
              },
            ),
        ]),
      ]);
}
