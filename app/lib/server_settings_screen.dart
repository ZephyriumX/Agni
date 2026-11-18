import 'package:flutter/material.dart';

import 'api.dart';
import 'capture_validation.dart';
import 'config.dart';
import 'widgets.dart';

/// Where the app's server lives. Reachable before sign-in (welcome screen) and from Profile.
class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({super.key});
  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  List<DiagStep>? _steps;
  bool _busy = false;
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
    _cameraKey = await AppConfig.cameraKey();
    if (mounted) setState(() {});
    _cfg = await Api.captureConfig();
    if (mounted) setState(() {});
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _steps = null;
    });
    await AppConfig.setBaseUrl(_url.text);
    await AppConfig.setRegistrationKey(_key.text);
    _url.text = await AppConfig.baseUrl();
    final s = await Api.diagnose();
    _cfg = await Api.captureConfig();
    if (mounted) {
      setState(() {
        _steps = s;
        _busy = false;
      });
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final builtIn = AppConfig.builtInBaseUrl;
    final insecure = _url.text.startsWith('http://') &&
        !(_url.text.contains('127.0.0.1') ||
            _url.text.contains('localhost') ||
            _url.text.contains('10.0.2.2'));
    return Scaffold(
      appBar: AppBar(title: const Text('Server & device')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SectionCard(
          title: 'Server',
          icon: Icons.dns_outlined,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
                'Your account and history live on this server. Use your cloud address (https://...) to use the '
                'app anywhere without a cable.',
                style: TextStyle(height: 1.35)),
            const SizedBox(height: 14),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                  labelText: 'Server address',
                  hintText: 'https://agni-pulse-api.onrender.com',
                  prefixIcon: Icon(Icons.link)),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              if (builtIn.isNotEmpty)
                ActionChip(
                    avatar: const Icon(Icons.cloud_outlined, size: 18),
                    label: const Text('Cloud (built in)'),
                    onPressed: () => setState(() => _url.text = builtIn)),
              ActionChip(
                  avatar: const Icon(Icons.usb, size: 18),
                  label: const Text('USB cable (adb reverse)'),
                  onPressed: () =>
                      setState(() => _url.text = 'http://127.0.0.1:8000')),
              ActionChip(
                  avatar: const Icon(Icons.phone_android, size: 18),
                  label: const Text('Emulator'),
                  onPressed: () =>
                      setState(() => _url.text = 'http://10.0.2.2:8000')),
            ]),
            if (insecure)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: InfoBanner(
                    tone: CaptureStatus.warning,
                    icon: Icons.lock_open,
                    text:
                        'Plain http over Wi-Fi or the internet sends your password unencrypted. Use an https '
                        'address (cloud deployment or tunnel) outside your own network.'),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Invitation key (only if the server requires one)',
                  prefixIcon: Icon(Icons.key)),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.network_check),
              onPressed: _busy ? null : _test,
              label: Text(_busy
                  ? 'Testing (a sleeping server can take a minute)…'
                  : 'Save & test connection'),
            ),
            if (_steps != null) ...[
              const SizedBox(height: 8),
              for (final s in _steps!)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(s.ok ? Icons.check_circle : Icons.cancel,
                      color: s.ok ? Colors.green : cs.error),
                  title: Text(s.name),
                  subtitle: SelectableText(s.detail),
                ),
            ],
          ]),
        ),
        SectionCard(
          title: 'Camera',
          icon: Icons.photo_camera_outlined,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_cameraKey == null
                ? 'Automatic: the fastest usable back camera is chosen (high-speed mode when needed).'
                : 'Using camera "$_cameraKey" (chosen on the scan screen).'),
            const SizedBox(height: 4),
            Text(
                'Change it on the scan screen (Camera > Change). Only back cameras with a flash are offered.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
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
              'minimum ${_cfg.hardMinFps.toStringAsFixed(0)} fps. Frame drops over '
              '${(_cfg.hardMaxDropRatio * 100).toStringAsFixed(0)}% or gaps over '
              '${(_cfg.hardMaxGapS * 1000).toStringAsFixed(0)} ms are rejected. These are engineering limits set by '
              'the server, not medical ones.',
              style: const TextStyle(fontSize: 13, height: 1.35)),
        ),
      ]),
    );
  }
}
