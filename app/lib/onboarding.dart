import 'package:flutter/material.dart';

import 'api.dart';
import 'capture_validation.dart';
import 'format.dart';
import 'prakriti.dart';
import 'session.dart';
import 'widgets.dart';

const goalOptions = {
  'digestion': ('Digestion', Icons.restaurant),
  'stress': ('Stress', Icons.self_improvement),
  'energy': ('Energy', Icons.bolt),
  'sleep': ('Sleep', Icons.bedtime_outlined),
  'heart_health': ('Heart health', Icons.favorite_border),
  'weight': ('Weight', Icons.monitor_weight_outlined),
  'fitness': ('Fitness', Icons.directions_run),
  'curiosity': ('Just curious', Icons.science_outlined),
};
const sexOptions = {
  'female': 'Female',
  'male': 'Male',
  'other': 'Other',
  'prefer_not': 'Prefer not to say'
};
const dietOptions = {
  'vegetarian': 'Vegetarian',
  'eggetarian': 'Eggetarian',
  'vegan': 'Vegan',
  'jain': 'Jain',
  'non_vegetarian': 'Non-vegetarian',
  'other': 'Other',
};
const activityOptions = {
  'sedentary': 'Mostly sitting',
  'light': 'Light',
  'moderate': 'Moderate',
  'active': 'Very active',
};

String goalLabel(String k) => goalOptions[k]?.$1 ?? capitalise(k);

/// Editable copy of the personalisation profile. PATCH replaces the whole `profile` object, so every field the
/// server already had is carried through.
class ProfileDraft {
  String name;
  Map<String, dynamic> extra;
  int? birthYear;
  String? sex, diet, activity;
  Set<String> goals;

  ProfileDraft(this.name, this.extra, this.birthYear, this.sex, this.diet,
      this.activity, this.goals);

  factory ProfileDraft.from(Map<String, dynamic>? user) {
    final p = Map<String, dynamic>.from(
        (user?['profile'] ?? const <String, dynamic>{}) as Map);
    return ProfileDraft(
      (user?['display_name'] as String?) ?? '',
      p,
      (p['birth_year'] as num?)?.toInt(),
      p['sex'] as String?,
      p['diet'] as String?,
      p['activity'] as String?,
      ((p['goals'] as List?) ?? const <dynamic>[]).map((e) => '$e').toSet(),
    );
  }

  Map<String, dynamic> toPatch() {
    final profile = <String, dynamic>{
      ...extra,
      'birth_year': birthYear,
      'sex': sex,
      'diet': diet,
      'activity': activity,
      'goals': goals.toList(),
    }..removeWhere((k, v) => v == null);
    return {'display_name': name.trim(), 'profile': profile};
  }
}

// =============================================================================== reusable parts
class ChoiceWrap extends StatelessWidget {
  final Map<String, String> options;
  final String? value;
  final ValueChanged<String?> onChanged;
  const ChoiceWrap(
      {super.key,
      required this.options,
      required this.value,
      required this.onChanged});
  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in options.entries)
          ChoiceChip(
            label: Text(e.value),
            selected: value == e.key,
            onSelected: (s) => onChanged(s ? e.key : null),
          ),
      ]);
}

class AboutYouForm extends StatefulWidget {
  final ProfileDraft draft;
  const AboutYouForm({super.key, required this.draft});
  @override
  State<AboutYouForm> createState() => _AboutYouFormState();
}

class _AboutYouFormState extends State<AboutYouForm> {
  late final _name = TextEditingController(text: widget.draft.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final tt = Theme.of(context).textTheme;
    final thisYear = DateTime.now().year;
    Widget label(String s) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(s, style: tt.titleSmall));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _name,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
            labelText: 'Name', prefixIcon: Icon(Icons.person_outline)),
        onChanged: (v) => d.name = v,
      ),
      label('Year of birth'),
      DropdownButtonFormField<int>(
        initialValue: d.birthYear,
        isExpanded: true,
        decoration:
            const InputDecoration(prefixIcon: Icon(Icons.cake_outlined)),
        hint: const Text('Select'),
        items: [
          for (var y = thisYear - 12; y >= 1925; y--)
            DropdownMenuItem(value: y, child: Text('$y')),
        ],
        onChanged: (v) => setState(() => d.birthYear = v),
      ),
      label('Sex'),
      ChoiceWrap(
          options: sexOptions,
          value: d.sex,
          onChanged: (v) => setState(() => d.sex = v)),
      label('Diet'),
      ChoiceWrap(
          options: dietOptions,
          value: d.diet,
          onChanged: (v) => setState(() => d.diet = v)),
      label('Daily activity'),
      ChoiceWrap(
          options: activityOptions,
          value: d.activity,
          onChanged: (v) => setState(() => d.activity = v)),
      const SizedBox(height: 12),
      Text(
          'Used only to personalise guidance and to describe your own results. All optional.',
          style: tt.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
  }
}

class GoalsPicker extends StatefulWidget {
  final ProfileDraft draft;
  const GoalsPicker({super.key, required this.draft});
  @override
  State<GoalsPicker> createState() => _GoalsPickerState();
}

class _GoalsPickerState extends State<GoalsPicker> {
  @override
  Widget build(BuildContext context) {
    final g = widget.draft.goals;
    return Wrap(spacing: 10, runSpacing: 10, children: [
      for (final e in goalOptions.entries)
        FilterChip(
          avatar: Icon(e.value.$2, size: 18),
          label: Text(e.value.$1),
          selected: g.contains(e.key),
          onSelected: (s) => setState(() {
            if (s) {
              g.add(e.key);
            } else {
              g.remove(e.key);
            }
          }),
        ),
    ]);
  }
}

/// One question per page with large tap targets; calls [onDone] with the scored result.
class PrakritiQuiz extends StatefulWidget {
  final ValueChanged<PrakritiResult> onDone;
  const PrakritiQuiz({super.key, required this.onDone});
  @override
  State<PrakritiQuiz> createState() => _PrakritiQuizState();
}

class _PrakritiQuizState extends State<PrakritiQuiz> {
  final _answers = <int, String>{};
  int _i = 0;
  bool _advancing = false;

  void _pick(String dosha) {
    if (_advancing) return;
    setState(() {
      _answers[_i] = dosha;
      _advancing = true;
    });
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() => _advancing = false);
      if (_i < prakritiQuestions.length - 1) {
        setState(() => _i++);
      } else {
        widget.onDone(scorePrakriti(_answers));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = prakritiQuestions[_i];
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('Question ${_i + 1} of ${prakritiQuestions.length}',
            style: TextStyle(color: cs.onSurfaceVariant)),
        const Spacer(),
        if (_i > 0)
          TextButton(
              onPressed: () => setState(() => _i--), child: const Text('Back')),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
            value: (_i + 1) / prakritiQuestions.length, minHeight: 6),
      ),
      const SizedBox(height: 22),
      Text(q.title,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(
          'Choose what has been true for most of your life, not just recently.',
          style: TextStyle(color: cs.onSurfaceVariant)),
      const SizedBox(height: 18),
      for (final o in q.options)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: _answers[_i] == o.dosha
                ? cs.primaryContainer
                : cs.surfaceContainerHighest.withAlpha(120),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _pick(o.dosha),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Row(children: [
                  Icon(
                      _answers[_i] == o.dosha
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      color: _answers[_i] == o.dosha ? cs.primary : cs.outline),
                  const SizedBox(width: 12),
                  Expanded(
                      child:
                          Text(o.label, style: const TextStyle(fontSize: 16))),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

class PrakritiResultCard extends StatelessWidget {
  final String type;
  final Map<String, dynamic>? scores;
  const PrakritiResultCard({super.key, required this.type, this.scores});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = (scores?['vata'] as num?)?.toDouble() ?? 0;
    final p = (scores?['pitta'] as num?)?.toDouble() ?? 0;
    final k = (scores?['kapha'] as num?)?.toDouble() ?? 0;
    final total = v + p + k;
    Widget bar(String name, double x, Color c) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            SizedBox(width: 56, child: Text(name)),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                    value: total == 0 ? 0 : x / total,
                    minHeight: 12,
                    color: c,
                    backgroundColor: c.withAlpha(40)),
              ),
            ),
            SizedBox(
                width: 48,
                child:
                    Text(total == 0 ? '' : ' ${(x / total * 100).round()}%')),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(type,
          style: Theme.of(context)
              .textTheme
              .headlineMedium
              ?.copyWith(fontWeight: FontWeight.w800, color: cs.primary)),
      const SizedBox(height: 6),
      Text(prakritiDescriptions[type] ?? '',
          style: const TextStyle(height: 1.4)),
      if (total > 0) ...[
        const SizedBox(height: 16),
        bar('Vata', v, const Color(0xFF5B8DEF)),
        bar('Pitta', p, const Color(0xFFE2570B)),
        bar('Kapha', k, const Color(0xFF2E9E6A)),
      ],
    ]);
  }
}

// =============================================================================== onboarding flow
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});
  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late final ProfileDraft _draft = ProfileDraft.from(Session.instance.user);
  int _step = 0; // 0 about, 1 goals, 2 quiz, 3 result
  PrakritiResult? _result;
  bool _saving = false;
  String? _error;

  Future<void> _finish() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final u = await Api.updateProfile({
        ..._draft.toPatch(),
        if (_result != null) 'prakriti_type': _result!.type,
        if (_result != null) 'prakriti_scores': _result!.scores,
        'onboarding_complete': true,
      });
      Session.instance.setUser(u); // the root gate now shows the app
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _saving = false;
        });
      }
    }
  }

  Widget _body() {
    switch (_step) {
      case 0:
        return AboutYouForm(draft: _draft);
      case 1:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Pick any that apply. Your insights put these first.'),
          const SizedBox(height: 16),
          GoalsPicker(draft: _draft),
        ]);
      case 2:
        return PrakritiQuiz(
            onDone: (r) => setState(() {
                  _result = r;
                  _step = 3;
                }));
      default:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_result != null)
            PrakritiResultCard(type: _result!.type, scores: _result!.scores),
          const SizedBox(height: 20),
          const SectionCard(
            title: 'How Agni-Pulse uses this',
            icon: Icons.tune,
            child: Text(
                'Your insights include guidance traditionally suggested for your constitution, and highlight the meals '
                'and habits most relevant to it. It is a self-assessment for wellness context, not a diagnosis. You '
                'can retake it any time from Profile.',
                style: TextStyle(height: 1.4)),
          ),
          const SectionCard(
            title: 'Next: your baseline',
            icon: Icons.flag_outlined,
            child: Text(
                'Record 3 baseline scans on different days (rested, seated, ideally in the morning before food or '
                'coffee). They define your normal range, so the app can tell real changes from everyday noise.',
                style: TextStyle(height: 1.4)),
          ),
          if (_error != null)
            InfoBanner(tone: CaptureStatus.fail, text: _error!),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    const titles = [
      'About you',
      'What brings you here?',
      'Your Prakriti',
      'Your constitution'
    ];
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text('Step ${_step + 1} of 4'),
        leading: (_step == 1 || _step == 3)
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    setState(() => _step = _step == 3 ? 2 : _step - 1))
            : null,
        actions: [
          if (_step < 2)
            TextButton(
                onPressed: () => setState(() => _step++),
                child: const Text('Skip')),
          if (_step == 2)
            TextButton(
                onPressed: () => setState(() => _step = 3),
                child: const Text('Skip quiz')),
        ],
      ),
      body: SafeArea(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
              if (_step != 2) ...[
                Text(
                    _step == 0
                        ? 'Hi ${Session.instance.displayName}!'
                        : titles[_step],
                    style: tt.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                if (_step == 0)
                  Text('A few details help personalise your insights.',
                      style: tt.bodyLarge),
                const SizedBox(height: 18),
              ] else ...[
                Text(
                    'A 12-question self-assessment of your Ayurvedic constitution (dosha balance).',
                    style: tt.bodyMedium),
                const SizedBox(height: 16),
              ],
              _body(),
            ]),
      ),
      bottomNavigationBar: _step == 2
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: FilledButton(
                  onPressed: _saving
                      ? null
                      : (_step == 3 ? _finish : () => setState(() => _step++)),
                  child: Text(_step == 3
                      ? (_saving ? 'Saving…' : 'Start using Agni-Pulse')
                      : 'Continue'),
                ),
              ),
            ),
    );
  }
}

// =============================================================================== edit later (from Profile)
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});
  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final ProfileDraft _draft = ProfileDraft.from(Session.instance.user);
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      Session.instance.setUser(await Api.updateProfile(_draft.toPatch()));
      if (mounted) Navigator.pop(context);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Edit profile'), actions: [
          TextButton(
              onPressed: _saving ? null : _save, child: const Text('Save')),
        ]),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          AboutYouForm(draft: _draft),
          const SizedBox(height: 24),
          Text('Goals', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          GoalsPicker(draft: _draft),
          const SizedBox(height: 24),
          FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save changes')),
        ]),
      );
}

class RetakePrakritiScreen extends StatefulWidget {
  const RetakePrakritiScreen({super.key});
  @override
  State<RetakePrakritiScreen> createState() => _RetakePrakritiScreenState();
}

class _RetakePrakritiScreenState extends State<RetakePrakritiScreen> {
  PrakritiResult? _r;
  bool _saving = false;

  Future<void> _save() async {
    final r = _r;
    if (r == null) return;
    setState(() => _saving = true);
    try {
      Session.instance.setUser(await Api.updateProfile(
          {'prakriti_type': r.type, 'prakriti_scores': r.scores}));
      if (mounted) Navigator.pop(context);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: AppBar(title: const Text('Prakriti self-assessment')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        if (r == null)
          PrakritiQuiz(onDone: (x) => setState(() => _r = x))
        else ...[
          PrakritiResultCard(type: r.type, scores: r.scores),
          const SizedBox(height: 12),
          if (Session.instance.prakriti != null &&
              Session.instance.prakriti != r.type)
            InfoBanner(
                text:
                    'Previously: ${Session.instance.prakriti}. Saving replaces it.'),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save result')),
          TextButton(
              onPressed: () => setState(() => _r = null),
              child: const Text('Retake')),
        ],
        const SizedBox(height: 12),
        Text('Self-assessment for wellness context only.',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
