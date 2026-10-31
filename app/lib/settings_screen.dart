import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api.dart';
import 'config.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  List<DiagStep>? _steps;
  bool _busy = false;
  String _device = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _url.text = await AppConfig.baseUrl();
    _key.text = await AppConfig.registrationKey();
    _device = await AppConfig.isPhysicalDevice() ? 'physical phone' : 'emulator';
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    await AppConfig.setBaseUrl(_url.text);
    await AppConfig.setRegistrationKey(_key.text);
  }

  Future<void> _test() async {
    setState(() { _busy = true; _steps = null; });
    await _save();
    final s = await Api.diagnose();
    if (mounted) setState(() { _steps = s; _busy = false; });
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server & diagnostics')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Running on: $_device'),
        const SizedBox(height: 8),
        TextField(controller: _url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'API base URL')),
        Wrap(spacing: 8, children: [
          ActionChip(label: const Text('USB (adb reverse)'), onPressed: () => setState(() => _url.text = 'http://127.0.0.1:8000')),
          ActionChip(label: const Text('Emulator'), onPressed: () => setState(() => _url.text = 'http://10.0.2.2:8000')),
        ]),
        TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'Registration key (only if the server requires one)')),
        const SizedBox(height: 12),
        FilledButton(onPressed: _busy ? null : _test, child: Text(_busy ? 'Testing…' : 'Save & test connection')),
        if (_steps != null) ...[
          const SizedBox(height: 12),
          for (final s in _steps!)
            ListTile(
              dense: true,
              leading: Icon(s.ok ? Icons.check_circle : Icons.cancel, color: s.ok ? Colors.green : Colors.red),
              title: Text(s.name),
              subtitle: SelectableText(s.detail),
            ),
        ],
        const Divider(height: 32),
        OutlinedButton(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Reset profile on this phone?'),
                content: const Text('This forgets your login token. Your saved history stays on the server but becomes unreachable from this phone.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                  TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
                ],
              ),
            );
            if (ok == true) {
              await AppConfig.clearCredentials();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile reset')));
            }
          },
          child: const Text('Reset profile'),
        ),
        TextButton(
          onPressed: () async {
            final u = await AppConfig.userId();
            await Clipboard.setData(ClipboardData(text: u ?? ''));
          },
          child: const Text('Copy my user id'),
        ),
      ]),
    );
  }
}
