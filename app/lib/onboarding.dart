import 'package:flutter/material.dart';

/// One-time notice shown before first use. Wording is deliberately plain: this is a wellness / research
/// prototype, not a medical device.
class OnboardingScreen extends StatelessWidget {
  final VoidCallback onAccept;
  const OnboardingScreen({super.key, required this.onAccept});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget point(IconData i, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(body, style: t.bodyMedium),
            ])),
          ]),
        );
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 12),
          Text('Agni-Pulse', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Vascular wellness from your phone camera', style: t.titleMedium),
          const SizedBox(height: 28),
          point(Icons.fingerprint, 'How it works',
              'Cover the rear camera and flash with your fingertip. The app reads tiny colour changes with each heartbeat '
              '(photoplethysmography) and derives heart rate, variability and a pulse-wave shape index.'),
          point(Icons.health_and_safety_outlined, 'Not a medical device',
              'Results are for wellness and research use only. They do not diagnose, treat or prevent any condition. '
              'Talk to a doctor about health concerns.'),
          point(Icons.camera_alt_outlined, 'Camera only',
              'The app asks for camera access only (no microphone, no location). Scans are sent to the server you configure.'),
          point(Icons.rule, 'Honest quality checks',
              'A scan is rejected when the camera frame rate or the signal quality is too low. It is never accepted just to look good.'),
          const SizedBox(height: 12),
          FilledButton(onPressed: onAccept, child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12), child: Text('I understand, continue'))),
        ]),
      ),
    );
  }
}
