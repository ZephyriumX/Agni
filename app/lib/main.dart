import 'package:flutter/material.dart';
import 'api.dart';
import 'diary_screen.dart';
import 'pending_queue.dart';
import 'quiz_screen.dart';
import 'report_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';
import 'timer_screen.dart';

void main() => runApp(const AgniPulseApp());

class AgniPulseApp extends StatelessWidget {
  const AgniPulseApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Agni-Pulse',
        theme:
            ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _server = 'checking server…';
  Color _serverColor = Colors.grey;
  int _pending = 0;
  String? _prakriti;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final steps = await Api.diagnose();
    final bad = steps.where((s) => !s.ok).toList();
    var pending = await PendingQueue.count();
    if (bad.isEmpty && pending > 0) {
      await PendingQueue.flush();
      pending = await PendingQueue.count();
    }
    String? pr;
    if (bad.isEmpty) {
      try {
        pr = (await Api.me())['prakriti_type'] as String?;
      } on ApiError catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _prakriti = pr;
      if (bad.isEmpty) {
        _server = 'Server connected';
        _serverColor = Colors.green;
      } else {
        _server = '${bad.first.name}: tap for details';
        _serverColor = Colors.red;
      }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agni-Pulse'), actions: [
        IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _go(const SettingsScreen())),
      ]),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        const Text('Vascular & autonomic check using your phone camera.',
            style: TextStyle(fontSize: 16)),
        const SizedBox(height: 12),
        ActionChip(
          avatar: Icon(Icons.circle, size: 12, color: _serverColor),
          label: Text(_server),
          onPressed: () => _go(const SettingsScreen()),
        ),
        if (_pending > 0)
          Card(
            color: Colors.amber.shade50,
            child: ListTile(
              leading: const Icon(Icons.cloud_upload),
              title: Text('$_pending scan(s) waiting to upload'),
              subtitle: const Text('Saved on this phone. Tap to retry.'),
              onTap: _refresh,
            ),
          ),
        const SizedBox(height: 16),
        if (_prakriti == null)
          OutlinedButton.icon(
              icon: const Icon(Icons.spa),
              label: const Text('Prakriti quiz (1 min)'),
              onPressed: () => _go(const QuizScreen()))
        else
          Text('Prakriti: $_prakriti'),
        const SizedBox(height: 12),
        FilledButton.icon(
            icon: const Icon(Icons.favorite),
            label: const Text('New scan'),
            onPressed: () => _go(const ScanScreen())),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            icon: const Icon(Icons.insights),
            label: const Text('Metabolic report'),
            onPressed: () => _go(const ReportScreen())),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            icon: const Icon(Icons.restaurant),
            label: const Text('Food diary'),
            onPressed: () => _go(const DiaryScreen())),
        const SizedBox(height: 24),
        const Text(
            'Tip: record a Baseline first (rested, seated). Then scan 30 min after a meal, and again after 10 min of Vajrasana.',
            style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 8),
        const Text('Wellness tool, not a medical device.',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      ]),
    );
  }
}
