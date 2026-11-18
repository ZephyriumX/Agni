import 'package:flutter/material.dart';

/// "How it works" page: the method and its limits, written for a reviewer.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget h(String s) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text(s,
            style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)));
    Widget p(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s, style: t.bodyMedium));
    return Scaffold(
      appBar: AppBar(title: const Text('How it works')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text('About Agni-Pulse',
            style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        h('Measurement'),
        p('The phone camera and flash record your fingertip. Each frame\'s average red/green value rises and falls with '
            'blood volume. Frames carry the sensor\'s own timestamps, so the real sampling rate is measured, never assumed.'),
        h('Derived values'),
        p('BPM and RMSSD (beat-to-beat variability) come from detected pulse peaks. The b/a ratio is taken from the second '
            'derivative of the pulse wave (acceleration plethysmogram) and is an experimental vascular-stiffness indicator.'),
        h('Frame rate'),
        p('Pulse-wave shape needs at least about 55 frames per second. Phones that limit normal camera access to 30 fps '
            'may still offer a high-speed mode (60-240 fps). The app uses it automatically and shows which mode ran. '
            'Frame rate and signal quality are checked separately; failing either fails the scan.'),
        h('Personal analytics'),
        p('Your baseline is the average of your good-quality Baseline scans; its spread is your normal day-to-day '
            'variation. Later scans are compared with it: a change bigger than twice that spread is shown as "clear". '
            'Meals and practices are ranked from the scans you tag with them, with a confidence level that grows with '
            'the number of scans.'),
        h('Your account and data'),
        p('Scans, meals, profile and Prakriti are stored on your server under your account and are available on any '
            'phone you sign in on. Only you can read them; passwords and recovery codes are stored only as one-way '
            'hashes. You can delete your account and all its data from Profile.'),
        h('Limits'),
        p('Motion, cold fingers, pressure and ambient light all affect results. This is a prototype for demonstration and '
            'research; it has not been clinically validated and is not a medical device.'),
      ]),
    );
  }
}
