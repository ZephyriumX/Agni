import 'package:flutter/material.dart';

import 'api.dart';
import 'auth_screens.dart';
import 'config.dart';
import 'diary_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'insights_screen.dart';
import 'onboarding.dart';
import 'profile_screen.dart';
import 'scan_screen.dart';
import 'server_settings_screen.dart';
import 'session.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AgniPulseApp());
}

class AgniPulseApp extends StatelessWidget {
  const AgniPulseApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Agni-Pulse',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: const RootGate(),
      );
}

/// Decides what the user sees: sign-in, legacy upgrade, onboarding, or the app. Rebuilds whenever the
/// session changes (sign-in, sign-out, onboarding finished, session expired on the server).
class RootGate extends StatefulWidget {
  const RootGate({super.key});
  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  final _session = Session.instance;
  bool _booting = true;
  Object? _bootError;
  bool _skipUpgrade = false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    _boot();
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    setState(() {
      _booting = true;
      _bootError = null;
    });
    try {
      if (await AppConfig.token() != null)
        await Api.wake(); // a sleeping cloud server needs time
      await _session.restore();
    } on ApiError catch (e) {
      // Signed in but the server cannot be reached: keep the login and offer retry / offline scanning.
      if (e.kind != ApiErrorKind.unauthorized) _bootError = e;
    } catch (e) {
      _bootError = e;
    }
    if (mounted) setState(() => _booting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) return const _Splash();
    if (_bootError != null) {
      return _Offline(
        error: _bootError!,
        onRetry: _boot,
        onOffline: () => setState(() {
          _bootError = null;
          _session.signedIn =
              true; // cached token: scans are queued and uploaded later
        }),
      );
    }
    if (!_session.signedIn) return const WelcomeScreen();
    if (_session.legacy && !_skipUpgrade) {
      return UpgradeAccountScreen(
          onSkip: () => setState(() => _skipUpgrade = true));
    }
    if (_session.user != null && !_session.onboarded)
      return const OnboardingFlow();
    return const AppShell();
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.local_fire_department, size: 64, color: cs.primary),
          const SizedBox(height: 16),
          const Text('Agni-Pulse',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 24),
          const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 12),
          Text('Connecting to your server…',
              style: TextStyle(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _Offline extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry, onOffline;
  const _Offline(
      {required this.error, required this.onRetry, required this.onOffline});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const SizedBox(height: 24),
            Icon(Icons.cloud_off,
                size: 56, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text("Can't reach your server",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            SelectableText('$error', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again')),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.dns_outlined),
              label: const Text('Server settings'),
              onPressed: () async {
                await Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ServerSettingsScreen()));
                onRetry();
              },
            ),
            TextButton(
                onPressed: onOffline,
                child: const Text('Continue offline (scans upload later)')),
          ]),
        ),
      );
}

/// Bottom navigation: Home · Insights · History · Diary · Profile. Tabs are built when first opened and kept.
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  final _visited = <int>{0};
  final _keys = List.generate(5, (_) => UniqueKey());

  void _open(int i) => setState(() {
        _tab = i;
        _visited.add(i);
      });

  /// After a scan, data on every tab may have changed: rebuild the visited ones.
  void refreshAll() => setState(() {
        for (var i = 0; i < _keys.length; i++) {
          if (i != _tab) _keys[i] = UniqueKey();
        }
      });

  Future<void> _scan([String tag = 'Baseline']) async {
    await Navigator.push<Object?>(context,
        MaterialPageRoute(builder: (_) => ScanScreen(initialTag: tag)));
    refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    Widget page(int i, Widget w) => _visited.contains(i)
        ? KeyedSubtree(key: _keys[i], child: w)
        : const SizedBox.shrink();
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        page(0, HomeScreen(onOpenTab: _open, onDataChanged: refreshAll)),
        page(1, InsightsScreen(onStartScan: () => _scan())),
        page(2, HistoryScreen(onStartScan: () => _scan())),
        page(3, const DiaryScreen()),
        page(4, const ProfileScreen()),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          if (i == _tab && i != 0) {
            setState(() => _keys[i] = UniqueKey()); // tap again = refresh
          }
          _open(i);
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'Insights'),
          NavigationDestination(
              icon: Icon(Icons.history),
              selectedIcon: Icon(Icons.history_toggle_off),
              label: 'History'),
          NavigationDestination(
              icon: Icon(Icons.restaurant_outlined),
              selectedIcon: Icon(Icons.restaurant),
              label: 'Diary'),
          NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Profile'),
        ],
      ),
    );
  }
}
