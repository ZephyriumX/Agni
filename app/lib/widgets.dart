import 'package:flutter/material.dart';

import 'capture_validation.dart';
import 'theme.dart';

/// Rounded pill showing a PASS / WARNING / FAIL (or neutral) state.
class StatusPill extends StatelessWidget {
  final CaptureStatus? status;
  final String label;
  const StatusPill({super.key, required this.status, required this.label});

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: s.bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: 16, color: s.fg),
        const SizedBox(width: 6),
        Flexible(child: Text(label, style: TextStyle(color: s.fg, fontWeight: FontWeight.w600, fontSize: 13))),
      ]),
    );
  }
}

/// Card with an optional icon + title row. Use instead of ad-hoc Card/Padding combinations.
class SectionCard extends StatelessWidget {
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  const SectionCard({
    super.key,
    this.title,
    this.icon,
    this.trailing,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: color ?? cs.surfaceContainerHighest.withAlpha(110),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: padding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                if (icon != null) ...[Icon(icon, size: 20, color: cs.primary), const SizedBox(width: 8)],
                Expanded(child: Text(title!, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                if (trailing != null) trailing!,
              ]),
            ),
          child,
        ]),
      ),
    );
  }
}

/// One headline number (b/a, RMSSD, heart rate...).
class MetricTile extends StatelessWidget {
  final String label, value;
  final String unit, hint;
  const MetricTile({super.key, required this.label, required this.value, this.unit = '', this.hint = ''});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 156,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(110),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          if (unit.isNotEmpty) ...[const SizedBox(width: 4), Text(unit, style: TextStyle(color: cs.onSurfaceVariant))],
        ]),
        if (hint.isNotEmpty) Text(hint, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

/// Inline message with an icon, tinted by status.
class InfoBanner extends StatelessWidget {
  final CaptureStatus? tone;
  final IconData? icon;
  final String text;
  final Widget? action;
  const InfoBanner({super.key, this.tone, this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(context, tone);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: s.bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon ?? s.icon, color: s.fg, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: s.fg, height: 1.35))),
        ]),
        if (action != null) Padding(padding: const EdgeInsets.only(top: 8), child: action),
      ]),
    );
  }
}

/// Numbered instruction row.
class StepRow extends StatelessWidget {
  final int n;
  final String text;
  const StepRow({super.key, required this.n, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: cs.primaryContainer,
          child: Text('$n', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.onPrimaryContainer)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(text))),
      ]),
    );
  }
}
