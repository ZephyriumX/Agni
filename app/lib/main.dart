import 'package:flutter/material.dart';

import 'api.dart';
import 'capture_validation.dart';
import 'diary_screen.dart';
import 'pending_queue.dart';
import 'quiz_screen.dart';
import 'report_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'timer_screen.dart';
import 'widgets.dart';

void main() => runApp(const AgniPulseApp());

class AgniPulseApp extends StatelessWidget {
  const AgniPulseApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Agni-Pulse',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: const AppShell(),
      );
}

/// Bottom navigation: Home / Report / Diary / Settings.
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(onOpenTab: (i) => setState(() => _tab = i)),
      if (_tab == 1) const ReportScreen() else const SizedBox.shrink(),
      if (_tab == 2) const DiaryScreen() else const SizedBox.shrink(),
      if (_tab == 3) const SettingsScreen() else const SizedBox.shrink(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'Report'),
          NavigationDestination(
              icon: Icon(Icons.restaurant_outlined),
              selectedIcon: Icon(Icons.restaurant),
              label: 'Diary'),
          NavigationDestination(
              icon: Icon(Icons.tune),
              selectedIcon: Icon(Icons.tune),
              label: 'Setup'),
        ],
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final void Function(int tab) onOpenTab;
  const HomeScreen({super.key, required this.onOpenTab});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _checking = true;
  bool _serverOk = false;
  String _serverMsg = 'Checking server…';
  int _pending = 0;
  String? _prakriti;
  Map<String, dynamic>? _last; // most recent scan summary from the server

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _checking = true);
    final steps = await Api.diagnose();
    final bad = steps.where((s) => !s.ok).toList();
    var pending = await PendingQueue.count();
    if (bad.isEmpty && pending > 0) {
      await PendingQueue.flush();
      pending = await PendingQueue.count();
    }
    String? pr;
    Map<String, dynamic>? last;
    if (bad.isEmpty) {
      try {
        pr = (await Api.me())['prakriti_type'] as String?;
        final rep = await Api.report();
        final scans = (rep['scans'] as List?) ?? const [];
        if (scans.isNotEmpty) {
          last = Map<String, dynamic>.from(scans.last as Map);
        }
      } on ApiError catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _pending = pending;
      _prakriti = pr;
      _last = last;
      _serverOk = bad.isEmpty;
      _serverMsg =
          bad.isEmpty ? 'Server connected' : '${bad.first.name}: tap to fix';
    });
  }

  Future<void> _go(Widget w) async {
    final r = await Navigator.push<Object?>(
        context, MaterialPageRoute<Object?>(builder: (_) => w));
    if (r is Map && r['vajrasana_for'] != null && mounted) {
      await Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) =>
                  TimerScreen(preScanId: r['vajrasana_for'] as String)));
    }
    _refresh();
  }

  String _n(dynamic v, [int d = 1]) =>
      v == null ? '—' : (v as num).toStringAsFixed(d);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
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
              onPressed: _refresh)
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: () => widget.onOpenTab(3),
                  child: StatusPill(
                    status: _checking
                        ? null
                        : (_serverOk ? CaptureStatus.pass : CaptureStatus.fail),
                    label: _checking ? 'Checking server…' : _serverMsg,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_pending > 0)
                InfoBanner(
                  tone: CaptureStatus.warning,
                  icon: Icons.cloud_upload_outlined,
                  text:
                      '$_pending scan(s) saved on this phone, waiting to upload.',
                  action: TextButton(
                      onPressed: _refresh, child: const Text('Retry now')),
                ),
              // ---- hero
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [cs.primary, cs.tertiary],
                  ),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Check your vascular tone',
                          style: tt.headlineSmall?.copyWith(
                              color: cs.onPrimary,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text(
                          'A 35-second fingertip scan with your phone camera and flash.',
                          style: tt.bodyMedium
                              ?.copyWith(color: cs.onPrimary.withAlpha(230))),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: cs.onPrimary,
                            foregroundColor: cs.primary),
                        icon: const Icon(Icons.favorite),
                        label: const Text('Start scan'),
                        onPressed: () => _go(const ScanScreen()),
                      ),
                    ]),
              ),
              const SizedBox(height: 16),
              // ---- last scan
              if (_last != null)
                SectionCard(
                  title: 'Last scan',
                  icon: Icons.history,
                  trailing: StatusPill(
                    status: _last!['sqi_passed'] == true
                        ? CaptureStatus.pass
                        : CaptureStatus.warning,
                    label: _last!['sqi_passed'] == true
                        ? 'Good quality'
                        : 'Poor quality',
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_last!['tag_event'] ?? ''}',
                            style: tt.labelLarge),
                        const SizedBox(height: 10),
                        Wrap(spacing: 10, runSpacing: 10, children: [
                          MetricTile(
                              label: 'b/a ratio',
                              value: _n(_last!['ba_ratio'], 2),
                              hint: 'more negative = more compliant'),
                          MetricTile(
                              label: 'RMSSD',
                              value: _n(_last!['rmssd']),
                              unit: 'ms'),
                          MetricTile(
                              label: 'Heart rate',
                              value: _n(_last!['avg_bpm'], 0),
                              unit: 'bpm'),
                        ]),
                      ]),
                ),
              // ---- journey
              const SectionCard(
                title: 'Your scan journey',
                icon: Icons.route,
                child: Column(children: [
                  StepRow(
                      n: 1,
                      text:
                          'Baseline: rested, seated, ideally in the morning.'),
                  StepRow(
                      n: 2,
                      text: 'Post-meal: scan about 30 minutes after eating.'),
                  StepRow(
                      n: 3,
                      text:
                          'Post-Vajrasana: scan again after 10 minutes of Vajrasana.'),
                ]),
              ),
              if (_prakriti == null)
                SectionCard(
                  title: 'Personalise',
                  icon: Icons.spa,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                            'A 1-minute Prakriti quiz tailors the guidance to you.'),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                            icon: const Icon(Icons.spa),
                            label: const Text('Take the quiz'),
                            onPressed: () => _go(const QuizScreen())),
                      ]),
                )
              else
                SectionCard(
                    title: 'Prakriti',
                    icon: Icons.spa,
                    child: Text(_prakriti!, style: tt.titleLarge)),
              const SizedBox(height: 4),
              Text('Wellness tool, not a medical device.',
                  textAlign: TextAlign.center,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
      ),
    );
  }
}
