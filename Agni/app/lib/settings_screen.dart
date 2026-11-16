import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api.dart';
import 'capture_validation.dart';
import 'config.dart';
import 'widgets.dart';

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
  String? _cameraKey;
  CaptureConfig _cfg = CaptureConfig.defaults;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _url.text = await AppConfig.baseUrl();
    _key.text = await AppConfig.registrationKey();
    _device = await AppConfig.isPhysicalDevice() ? 'physical phone' : 'emulator';
    _cameraKey = await AppConfig.cameraKey();
    _cfg = await Api.captureConfig();
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
      appBar: AppBar(title: const Text('Setup')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SectionCard(
          title: 'Camera',
          icon: Icons.photo_camera,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_cameraKey == null ? 'Automatic: the fastest usable back camera is chosen.' : 'Using camera "$_cameraKey" (chosen on the scan screen).'),
            const SizedBox(height: 6),
            const Text('Change the camera from the scan screen (Camera > Change). Only back cameras are offered.',
                style: TextStyle(fontSize: 12)),
            if (_cameraKey != null)
              TextButton(
                onPressed: () async {
                  await AppConfig.setCameraKey(null);
                  if (mounted) setState(() => _cameraKey = null);
                },
                child: const Text('Reset to automatic'),
              ),
          ]),
        ),
        SectionCard(
          title: 'Capture requirements',
          icon: Icons.speed,
          child: Text(
              'Target ${_cfg.targetFps.toStringAsFixed(0)} fps, preferred ${_cfg.preferredMinFps.toStringAsFixed(0)}+, '
              'minimum ${_cfg.hardMinFps.toStringAsFixed(0)} fps (from the server). Frame drops over '
              '${(_cfg.hardMaxDropRatio * 100).toStringAsFixed(0)}% or gaps over '
              '${(_cfg.hardMaxGapS * 1000).toStringAsFixed(0)} ms are rejected. These are engineering limits, not medical ones.',
              style: const TextStyle(fontSize: 13)),
        ),
        SectionCard(
          title: 'Server',
          icon: Icons.dns,
          child: Text('Running on: $_device'),
        ),
        const SizedBox(height: 4),
        TextField(controller: _url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'API base URL')),
        Wrap(spacing: 8, children: [
          ActionChip(label: const Text('Localhost (adb reverse / iOS simulator)'), onPressed: () => setState(() => _url.text = 'http://127.0.0.1:8000')),
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
