import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'capture_validation.dart';
import 'config.dart';
import 'server_settings_screen.dart';
import 'session.dart';
import 'widgets.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? validateEmail(String? v) => (v == null || !_emailRe.hasMatch(v.trim()))
    ? 'Enter a valid e-mail address'
    : null;

String? validateNewPassword(String? v, {String email = ''}) {
  final p = v ?? '';
  if (p.length < 8) return 'At least 8 characters';
  if (RegExp(r'^\d+$').hasMatch(p)) return 'Not only digits';
  if (email.isNotEmpty && p.toLowerCase() == email.trim().toLowerCase())
    return 'Must differ from your e-mail';
  return null;
}

/// Wakes a sleeping cloud server before an auth call, showing progress in [onStatus].
Future<T> withServer<T>(
    Future<T> Function() call, void Function(String) onStatus) async {
  onStatus('Connecting to server…');
  final sw = Stopwatch()..start();
  final slow = Future<void>.delayed(const Duration(seconds: 4), () {
    if (sw.isRunning)
      onStatus(
          'Waking up the server (free cloud servers sleep when idle, up to a minute)…');
  });
  try {
    await Api.wake();
  } finally {
    sw.stop();
  }
  slow.ignore();
  onStatus('');
  return call();
}

// =============================================================================== welcome
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  String _server = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await AppConfig.baseUrl();
    if (mounted) setState(() => _server = s);
  }

  Future<void> _open(Widget w) async {
    await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => w));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final notice = Session.instance.notice;
    return Scaffold(
      body: SafeArea(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            children: [
              Container(
                height: 76,
                width: 76,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: LinearGradient(colors: [cs.primary, cs.tertiary]),
                ),
                child: Icon(Icons.local_fire_department,
                    color: cs.onPrimary, size: 44),
              ),
              const SizedBox(height: 24),
              Text('Agni-Pulse',
                  style:
                      tt.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                  'Understand how meals, breathing and daily habits affect your pulse, using only your phone camera.',
                  style: tt.titleMedium
                      ?.copyWith(color: cs.onSurfaceVariant, height: 1.35)),
              const SizedBox(height: 28),
              const FeatureRow(
                  icon: Icons.fingerprint,
                  text:
                      '35-second fingertip scans: heart rate, HRV and pulse-wave shape'),
              const FeatureRow(
                  icon: Icons.insights,
                  text: 'Your personal baseline, trends and meal responses'),
              const FeatureRow(
                  icon: Icons.spa, text: 'Guidance tailored to your Prakriti'),
              const FeatureRow(
                  icon: Icons.cloud_done,
                  text: 'Your history follows your account on any phone'),
              const SizedBox(height: 24),
              if (notice != null)
                InfoBanner(icon: Icons.info_outline, text: notice),
              FilledButton(
                onPressed: () => _open(const SignupScreen()),
                child: const Text('Create account'),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () => _open(const LoginScreen()),
                child: const Text('I already have an account'),
              ),
              const SizedBox(height: 18),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.dns_outlined, size: 18),
                  label: Text(
                      'Server: ${_server.isEmpty ? '…' : Uri.tryParse(_server)?.host ?? _server}'),
                  onPressed: () => _open(const ServerSettingsScreen()),
                ),
              ),
              Text('Wellness tool, not a medical device.',
                  textAlign: TextAlign.center,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
      ),
    );
  }
}

class FeatureRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const FeatureRow({super.key, required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        CircleAvatar(
            radius: 18,
            backgroundColor: cs.primaryContainer,
            child: Icon(icon, size: 19, color: cs.onPrimaryContainer)),
        const SizedBox(width: 14),
        Expanded(child: Text(text, style: const TextStyle(height: 1.3))),
      ]),
    );
  }
}

// =============================================================================== shared form scaffold
class _AuthScaffold extends StatelessWidget {
  final String title, subtitle;
  final List<Widget> children;
  const _AuthScaffold(
      {required this.title, required this.subtitle, required this.children});
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: [
              Text(title,
                  style:
                      tt.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(subtitle,
                  style: tt.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 24),
              ...children,
            ]),
      ),
    );
  }
}

class PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final TextInputAction action;
  final VoidCallback? onSubmitted;
  final bool isNew;
  const PasswordField({
    super.key,
    required this.controller,
    this.label = 'Password',
    this.validator,
    this.action = TextInputAction.done,
    this.onSubmitted,
    this.isNew = false,
  });
  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _hide = true;
  @override
  Widget build(BuildContext context) => TextFormField(
        controller: widget.controller,
        obscureText: _hide,
        textInputAction: widget.action,
        autofillHints: [
          widget.isNew ? AutofillHints.newPassword : AutofillHints.password
        ],
        onFieldSubmitted: (_) => widget.onSubmitted?.call(),
        validator: widget.validator ??
            (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
        decoration: InputDecoration(
          labelText: widget.label,
          prefixIcon: const Icon(Icons.lock_outline),
          helperText: widget.isNew ? 'At least 8 characters' : null,
          suffixIcon: IconButton(
            icon: Icon(_hide
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined),
            tooltip: _hide ? 'Show password' : 'Hide password',
            onPressed: () => setState(() => _hide = !_hide),
          ),
        ),
      );
}

/// Busy / error / status lines shared by the forms.
mixin _FormState<T extends StatefulWidget> on State<T> {
  final form = GlobalKey<FormState>();
  bool busy = false;
  String? error;
  String status = '';

  Future<void> run(Future<void> Function() body) async {
    if (!(form.currentState?.validate() ?? true)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await body();
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) setState(() => error = 'Something went wrong: $e');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          status = '';
        });
      }
    }
  }

  void setStatus(String s) {
    if (mounted) setState(() => status = s);
  }

  List<Widget> feedback() => [
        if (status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Expanded(child: Text(status)),
            ]),
          ),
        if (error != null)
          InfoBanner(
              tone: CaptureStatus.fail,
              icon: Icons.error_outline,
              text: error!),
      ];
}

// =============================================================================== sign up
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});
  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> with _FormState {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _agree = false;
  bool _needsKey = false;
  final _key = TextEditingController();

  @override
  void initState() {
    super.initState();
    _options();
  }

  Future<void> _options() async {
    _key.text = await AppConfig.registrationKey();
    try {
      final o = await Api.authOptions();
      if (mounted)
        setState(() => _needsKey = o['registration_key_required'] == true);
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final c in [_name, _email, _pw, _pw2, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() => run(() async {
        if (!_agree) {
          setState(() => error =
              'Please confirm that you understand this is not a medical device.');
          return;
        }
        if (_needsKey) await AppConfig.setRegistrationKey(_key.text);
        final r = await withServer(
            () => Api.signup(_email.text, _pw.text, _name.text), setStatus);
        if (!mounted) return;
        await Navigator.pushReplacement(
            context,
            MaterialPageRoute<void>(
                builder: (_) =>
                    RecoveryCodeScreen(code: r.recoveryCode ?? '', result: r)));
      });

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Create your account',
        subtitle:
            'Your scans, baseline and insights are saved to your account and available on any phone.',
        children: [
          AutofillGroup(
            child: Form(
              key: form,
              child: Column(children: [
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  decoration: const InputDecoration(
                      labelText: 'Your name',
                      prefixIcon: Icon(Icons.person_outline)),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Enter your name'
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                      labelText: 'E-mail',
                      prefixIcon: Icon(Icons.alternate_email)),
                  validator: validateEmail,
                ),
                const SizedBox(height: 14),
                PasswordField(
                  controller: _pw,
                  isNew: true,
                  action: TextInputAction.next,
                  validator: (v) => validateNewPassword(v, email: _email.text),
                ),
                const SizedBox(height: 14),
                PasswordField(
                  controller: _pw2,
                  label: 'Repeat password',
                  validator: (v) =>
                      v != _pw.text ? 'Passwords do not match' : null,
                  onSubmitted: _submit,
                ),
                if (_needsKey) ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _key,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'Invitation key',
                        helperText: 'This server only accepts invited users',
                        prefixIcon: Icon(Icons.key)),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'Required on this server'
                        : null,
                  ),
                ],
              ]),
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _agree,
            onChanged: (v) => setState(() => _agree = v ?? false),
            title: const Text(
                'I understand Agni-Pulse is a wellness tool, not a medical device, and does not diagnose '
                'any condition.'),
          ),
          const SizedBox(height: 8),
          ...feedback(),
          FilledButton(
              onPressed: busy ? null : _submit,
              child: Text(busy ? 'Creating account…' : 'Create account')),
        ],
      );
}

// =============================================================================== recovery code
class RecoveryCodeScreen extends StatefulWidget {
  final String code;
  final AuthResult?
      result; // set during sign-up/recovery: signs in when the user continues
  const RecoveryCodeScreen({super.key, required this.code, this.result});
  @override
  State<RecoveryCodeScreen> createState() => _RecoveryCodeScreenState();
}

class _RecoveryCodeScreenState extends State<RecoveryCodeScreen> {
  bool _saved = false;
  bool _busy = false;

  Future<void> _continue() async {
    setState(() => _busy = true);
    if (widget.result != null) {
      await Session.instance.signedInWith(widget.result!);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: widget.result == null,
      child: Scaffold(
        appBar: AppBar(
            title: const Text('Your recovery code'),
            automaticallyImplyLeading: widget.result == null),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          const Text(
              'If you forget your password, this code lets you reset it. It is shown only once and works once '
              '(you get a new one after using it).',
              style: TextStyle(height: 1.4)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SelectableText(
              widget.code,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                  fontFamily: 'monospace',
                  color: cs.onPrimaryContainer),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy code'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.code));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'Copied. Paste it into your password manager or notes.')));
              }
            },
          ),
          const SizedBox(height: 16),
          const InfoBanner(
              icon: Icons.shield_outlined,
              text:
                  'Keep it somewhere safe and private (password manager, a note in another account, or on paper). '
                  'Anyone with your e-mail and this code can reset your password.'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _saved,
            onChanged: (v) => setState(() => _saved = v ?? false),
            title: const Text('I have saved my recovery code'),
          ),
          const SizedBox(height: 8),
          FilledButton(
              onPressed: _saved && !_busy ? _continue : null,
              child: const Text('Continue')),
        ]),
      ),
    );
  }
}

// =============================================================================== login
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with _FormState {
  final _email = TextEditingController();
  final _pw = TextEditingController();

  @override
  void initState() {
    super.initState();
    AppConfig.lastEmail().then((e) {
      if (mounted && _email.text.isEmpty) setState(() => _email.text = e);
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _submit() => run(() async {
        final r =
            await withServer(() => Api.login(_email.text, _pw.text), setStatus);
        await Session.instance.signedInWith(r);
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      });

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Welcome back',
        subtitle: 'Sign in to see your history on this phone.',
        children: [
          AutofillGroup(
            child: Form(
              key: form,
              child: Column(children: [
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                      labelText: 'E-mail',
                      prefixIcon: Icon(Icons.alternate_email)),
                  validator: validateEmail,
                ),
                const SizedBox(height: 14),
                PasswordField(controller: _pw, onSubmitted: _submit),
              ]),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          ForgotPasswordScreen(email: _email.text))),
              child: const Text('Forgot password?'),
            ),
          ),
          ...feedback(),
          FilledButton(
              onPressed: busy ? null : _submit,
              child: Text(busy ? 'Signing in…' : 'Sign in')),
        ],
      );
}

// =============================================================================== forgot password
class ForgotPasswordScreen extends StatefulWidget {
  final String email;
  const ForgotPasswordScreen({super.key, this.email = ''});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen>
    with _FormState {
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _pw = TextEditingController();
  bool _emailReset = false; // server can e-mail codes
  bool _useEmail = false; // user chose the e-mail route
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    Api.authOptions().then((o) {
      if (mounted) setState(() => _emailReset = o['email_reset'] == true);
    }).catchError((Object _) {});
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _sendEmail() => run(() async {
        await withServer(() => Api.forgot(_email.text), setStatus);
        if (mounted) setState(() => _sent = true);
      });

  Future<void> _reset() => run(() async {
        final AuthResult r;
        if (_useEmail) {
          r = await withServer(
              () => Api.resetWithCode(_email.text, _code.text, _pw.text),
              setStatus);
          await Session.instance.signedInWith(r);
          if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
        } else {
          r = await withServer(
              () => Api.recover(_email.text, _code.text, _pw.text), setStatus);
          if (!mounted) return;
          await Navigator.pushReplacement(
              context,
              MaterialPageRoute<void>(
                  builder: (_) => RecoveryCodeScreen(
                      code: r.recoveryCode ?? '', result: r)));
        }
      });

  @override
  Widget build(BuildContext context) {
    final codeLabel = _useEmail
        ? '6-digit code from the e-mail'
        : 'Recovery code (XXXX-XXXX-XXXX-XXXX)';
    return _AuthScaffold(
      title: 'Reset your password',
      subtitle: 'Use the recovery code you saved when you created the account'
          '${_emailReset ? ', or get a code by e-mail' : ''}. All other devices will be signed out.',
      children: [
        if (_emailReset)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: false,
                    label: Text('Recovery code'),
                    icon: Icon(Icons.key)),
                ButtonSegment(
                    value: true,
                    label: Text('E-mail code'),
                    icon: Icon(Icons.mail_outline)),
              ],
              selected: {_useEmail},
              onSelectionChanged: (s) => setState(() {
                _useEmail = s.first;
                error = null;
              }),
            ),
          ),
        Form(
          key: form,
          child: Column(children: [
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                  labelText: 'E-mail', prefixIcon: Icon(Icons.alternate_email)),
              validator: validateEmail,
            ),
            if (_useEmail && !_sent) ...[
              const SizedBox(height: 16),
              ...feedback(),
              FilledButton(
                  onPressed: busy ? null : _sendEmail,
                  child: const Text('E-mail me a code')),
            ] else ...[
              const SizedBox(height: 14),
              TextFormField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                keyboardType:
                    _useEmail ? TextInputType.number : TextInputType.text,
                decoration: InputDecoration(
                    labelText: codeLabel,
                    prefixIcon: const Icon(Icons.pin_outlined)),
                validator: (v) => (v == null || v.trim().length < 6)
                    ? 'Enter the code'
                    : null,
              ),
              const SizedBox(height: 14),
              PasswordField(
                controller: _pw,
                label: 'New password',
                isNew: true,
                validator: (v) => validateNewPassword(v, email: _email.text),
              ),
              const SizedBox(height: 16),
              if (_sent)
                const InfoBanner(
                    icon: Icons.mark_email_read_outlined,
                    text:
                        'If the account exists, a code is on its way. It expires in 15 minutes.'),
              ...feedback(),
              FilledButton(
                  onPressed: busy ? null : _reset,
                  child: const Text('Set new password')),
            ],
          ]),
        ),
        const SizedBox(height: 16),
        Text(
            'Lost both your password and recovery code? The server administrator can help; your data cannot be '
            'reached without one of them.',
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

// =============================================================================== legacy upgrade
/// For people who used v0.x (anonymous device profile): add e-mail + password, keeping every scan.
class UpgradeAccountScreen extends StatefulWidget {
  final VoidCallback onSkip;
  const UpgradeAccountScreen({super.key, required this.onSkip});
  @override
  State<UpgradeAccountScreen> createState() => _UpgradeAccountScreenState();
}

class _UpgradeAccountScreenState extends State<UpgradeAccountScreen>
    with _FormState {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pw = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _submit() => run(() async {
        final r = await withServer(
            () => Api.upgrade(_email.text, _pw.text, _name.text), setStatus);
        if (!mounted) return;
        await Navigator.push<void>(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    RecoveryCodeScreen(code: r.recoveryCode ?? '', result: r)));
      });

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Secure your data',
        subtitle:
            'This phone has scans from an earlier version saved under a device-only profile. Add an e-mail and '
            'password to keep them and use them on other phones.',
        children: [
          Form(
            key: form,
            child: Column(children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                    labelText: 'Your name',
                    prefixIcon: Icon(Icons.person_outline)),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'E-mail',
                    prefixIcon: Icon(Icons.alternate_email)),
                validator: validateEmail,
              ),
              const SizedBox(height: 14),
              PasswordField(
                controller: _pw,
                isNew: true,
                validator: (v) => validateNewPassword(v, email: _email.text),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          ...feedback(),
          FilledButton(
              onPressed: busy ? null : _submit,
              child: const Text('Create account with my data')),
          const SizedBox(height: 8),
          TextButton(onPressed: widget.onSkip, child: const Text('Not now')),
        ],
      );
}
