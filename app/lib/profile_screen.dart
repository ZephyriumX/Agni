import 'package:flutter/material.dart';

import 'about_screen.dart';
import 'api.dart';
import 'auth_screens.dart';
import 'capture_validation.dart';
import 'config.dart';
import 'format.dart';
import 'onboarding.dart';
import 'server_settings_screen.dart';
import 'session.dart';
import 'widgets.dart';

/// Account, personalisation, security, devices, server and about.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _s = Session.instance;
  String _server = '';

  @override
  void initState() {
    super.initState();
    _s.addListener(_changed);
    AppConfig.baseUrl().then((v) {
      if (mounted) setState(() => _server = v);
    });
    _s.refresh().catchError((Object _) {});
  }

  @override
  void dispose() {
    _s.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _push(Widget w) =>
      Navigator.push<void>(context, MaterialPageRoute(builder: (_) => w));

  Future<String?> _askPassword(String title, String message) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message),
          const SizedBox(height: 12),
          TextField(
              controller: c,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Password')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('Continue')),
        ],
      ),
    );
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _newRecoveryCode() async {
    final pw = await _askPassword(
        'New recovery code', 'Your old recovery code stops working.');
    if (pw == null || pw.isEmpty || !mounted) return;
    try {
      final code = await Api.newRecoveryCode(pw);
      if (mounted) await _push(RecoveryCodeScreen(code: code));
    } on ApiError catch (e) {
      if (mounted) _snack(e.message);
    }
  }

  Future<void> _signOut({bool everywhere = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(everywhere ? 'Sign out on all devices?' : 'Sign out?'),
        content: Text(everywhere
            ? 'Every phone signed in to this account, including this one, must sign in again.'
            : 'Your data stays in your account. Sign in again on any phone to see it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) await _s.signOut(everywhere: everywhere);
  }

  Future<void> _delete() async {
    final hasPw = _s.user?['has_password'] == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
            'This permanently deletes your account, every scan, meal, comparison and insight. It cannot '
            'be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(c).colorScheme.error),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete everything')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    String? pw;
    if (hasPw) {
      pw = await _askPassword('Confirm with your password',
          'Enter your password to delete the account.');
      if (pw == null || pw.isEmpty) return;
    }
    try {
      await Api.deleteAccount(password: pw);
      await _s.forget('Your account and all its data were deleted.');
    } on ApiError catch (e) {
      if (mounted) _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _s.user ?? const <String, dynamic>{};
    final p = _s.profile;
    final cs = Theme.of(context).colorScheme;
    final goals = ((p['goals'] as List?) ?? const <dynamic>[])
        .map((e) => goalLabel('$e'))
        .toList();
    final created = parseTs(u['created_at']);
    final details = [
      if (p['birth_year'] != null) 'born ${p['birth_year']}',
      if (p['sex'] != null) sexOptions['${p['sex']}'] ?? '${p['sex']}',
      if (p['diet'] != null) dietOptions['${p['diet']}'] ?? '${p['diet']}',
      if (p['activity'] != null)
        activityOptions['${p['activity']}'] ?? '${p['activity']}',
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            Row(children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: cs.primaryContainer,
                child: Text(
                    _s.displayName.isEmpty
                        ? '?'
                        : _s.displayName[0].toUpperCase(),
                    style: TextStyle(
                        fontSize: 26,
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s.displayName,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800)),
                      Text('${u['email'] ?? 'Device profile (no e-mail yet)'}',
                          style: TextStyle(color: cs.onSurfaceVariant)),
                      if (created != null)
                        Text('Member since ${fmtDate(created, year: true)}',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant)),
                    ]),
              ),
            ]),
            const SizedBox(height: 16),
            if (u['has_password'] == false)
              InfoBanner(
                tone: CaptureStatus.warning,
                icon: Icons.lock_open,
                text:
                    'This is a device-only profile from an earlier version. Add an e-mail and password to keep your data '
                    'safe and use it on other phones.',
                action: FilledButton.tonal(
                  onPressed: () => _push(UpgradeAccountScreen(
                      onSkip: () => Navigator.pop(context))),
                  child: const Text('Secure my data'),
                ),
              ),
            SectionCard(
              title: 'Personalisation',
              icon: Icons.spa_outlined,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.spa),
                      title: Text(_s.prakriti ?? 'Prakriti not set'),
                      subtitle: const Text(
                          'Ayurvedic constitution (self-assessment)'),
                      trailing: TextButton(
                          onPressed: () => _push(const RetakePrakritiScreen()),
                          child: Text(
                              _s.prakriti == null ? 'Take quiz' : 'Retake')),
                    ),
                    if (_s.prakriti != null && u['prakriti_scores'] != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: PrakritiResultCard(
                            type: _s.prakriti!,
                            scores: Map<String, dynamic>.from(
                                u['prakriti_scores'] as Map)),
                      ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline),
                      title: Text(details.isEmpty
                          ? 'About you: not set'
                          : details.join(' · ')),
                      subtitle: Text(goals.isEmpty
                          ? 'No goals chosen'
                          : 'Goals: ${goals.join(', ')}'),
                      trailing: TextButton(
                          onPressed: () => _push(const EditProfileScreen()),
                          child: const Text('Edit')),
                    ),
                  ]),
            ),
            SectionCard(
              title: 'Security',
              icon: Icons.shield_outlined,
              child: Column(children: [
                if (u['has_password'] == true) ...[
                  _tile(
                      Icons.password,
                      'Change password',
                      'Other devices are signed out',
                      () => _push(const ChangePasswordScreen())),
                  _tile(Icons.key, 'New recovery code',
                      'If you lost the old one', _newRecoveryCode),
                ],
                _tile(
                    Icons.devices,
                    'Signed-in devices',
                    'See where your account is used',
                    () => _push(const DevicesScreen())),
                _tile(Icons.logout, 'Sign out', 'This phone only',
                    () => _signOut()),
                _tile(
                    Icons.phonelink_erase,
                    'Sign out everywhere',
                    'All phones, including this one',
                    () => _signOut(everywhere: true)),
              ]),
            ),
            SectionCard(
              title: 'App',
              icon: Icons.settings_outlined,
              child: Column(children: [
                _tile(Icons.dns_outlined, 'Server & camera',
                    Uri.tryParse(_server)?.host ?? _server, () async {
                  await _push(const ServerSettingsScreen());
                  final v = await AppConfig.baseUrl();
                  if (mounted) setState(() => _server = v);
                }),
                _tile(
                    Icons.info_outline,
                    'How it works',
                    'Method, analytics and limits',
                    () => _push(const AboutScreen())),
              ]),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: cs.error,
                  side: BorderSide(color: cs.error.withAlpha(120))),
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Delete account and all data'),
              onPressed: _delete,
            ),
            const SizedBox(height: 16),
            Text('Agni-Pulse 1.0 · wellness tool, not a medical device.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ]),
    );
  }

  Widget _tile(IconData icon, String title, String sub, VoidCallback onTap) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
}

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _cur = TextEditingController();
  final _new = TextEditingController();
  final _new2 = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _cur.dispose();
    _new.dispose();
    _new2.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final n = await Api.changePassword(_cur.text, _new.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Password changed${n > 0 ? '; $n other device(s) signed out' : ''}.')));
      Navigator.pop(context);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Change password')),
        body: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(20), children: [
            PasswordField(
                controller: _cur,
                label: 'Current password',
                action: TextInputAction.next),
            const SizedBox(height: 14),
            PasswordField(
                controller: _new,
                label: 'New password',
                isNew: true,
                action: TextInputAction.next,
                validator: (v) => validateNewPassword(v,
                    email: '${Session.instance.user?['email'] ?? ''}')),
            const SizedBox(height: 14),
            PasswordField(
                controller: _new2,
                label: 'Repeat new password',
                validator: (v) =>
                    v != _new.text ? 'Passwords do not match' : null,
                onSubmitted: _save),
            const SizedBox(height: 16),
            if (_error != null)
              InfoBanner(tone: CaptureStatus.fail, text: _error!),
            FilledButton(
                onPressed: _busy ? null : _save,
                child: Text(_busy ? 'Saving…' : 'Change password')),
          ]),
        ),
      );
}

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  late Future<List<Map<String, dynamic>>> _f = Api.sessions();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Signed-in devices')),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _f,
          builder: (c, s) {
            if (s.connectionState != ConnectionState.done)
              return const LoadingView();
            if (s.hasError)
              return ErrorView(
                  error: s.error!,
                  onRetry: () => setState(() => _f = Api.sessions()));
            final rows = s.data!;
            if (rows.isEmpty) {
              return const EmptyView(
                  icon: Icons.devices,
                  title: 'No account sessions',
                  text:
                      'This phone uses a device profile from an earlier version.');
            }
            return ListView(padding: const EdgeInsets.all(16), children: [
              for (final r in rows)
                Card(
                  elevation: 0,
                  child: ListTile(
                    leading: Icon(r['current'] == true
                        ? Icons.smartphone
                        : Icons.devices_other),
                    title: Text(
                        '${r['device_name'] ?? 'Unknown device'}${r['current'] == true ? '  (this phone)' : ''}'),
                    subtitle: Text([
                      if (parseTs(r['created_at']) != null)
                        'signed in ${fmtDate(parseTs(r['created_at'])!, year: true)}',
                      if (parseTs(r['last_used_at']) != null)
                        'last active ${ago(parseTs(r['last_used_at'])!)}',
                    ].join(' · ')),
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                  'To remove other devices, use "Sign out everywhere" in Profile, or change your password.'),
            ]);
          },
        ),
      );
}
