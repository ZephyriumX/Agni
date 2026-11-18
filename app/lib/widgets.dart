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
      decoration:
          BoxDecoration(color: s.bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: 16, color: s.fg),
        const SizedBox(width: 6),
        Flexible(
            child: Text(label,
                style: TextStyle(
                    color: s.fg, fontWeight: FontWeight.w600, fontSize: 13))),
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
                if (icon != null) ...[
                  Icon(icon, size: 20, color: cs.primary),
                  const SizedBox(width: 8)
                ],
                Expanded(
                    child: Text(title!,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700))),
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
  const MetricTile(
      {super.key,
      required this.label,
      required this.value,
      this.unit = '',
      this.hint = ''});

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
        Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w800)),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(unit, style: TextStyle(color: cs.onSurfaceVariant))
              ],
            ]),
        if (hint.isNotEmpty)
          Text(hint,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
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
  const InfoBanner(
      {super.key, this.tone, this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(context, tone);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration:
          BoxDecoration(color: s.bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon ?? s.icon, color: s.fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text, style: TextStyle(color: s.fg, height: 1.35))),
        ]),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: action),
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
          child: Text('$n',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: cs.onPrimaryContainer)),
        ),
        const SizedBox(width: 10),
        Expanded(
            child: Padding(
                padding: const EdgeInsets.only(top: 2), child: Text(text))),
      ]),
    );
  }
}

/// Full-area spinner with an optional line of text.
class LoadingView extends StatelessWidget {
  final String text;
  const LoadingView({super.key, this.text = 'Loading…'});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
          ]),
        ),
      );
}

/// Error with a retry button (and the full message selectable for support).
class ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const ErrorView({super.key, required this.error, required this.onRetry});
  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(24), children: [
        Icon(Icons.cloud_off,
            size: 48, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 12),
        Text('Could not load',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        SelectableText('$error', textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again')),
      ]);
}

/// Friendly empty state with an optional call to action.
class EmptyView extends StatelessWidget {
  final IconData icon;
  final String title, text;
  final Widget? action;
  const EmptyView(
      {super.key,
      required this.icon,
      required this.title,
      required this.text,
      this.action});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(children: [
        CircleAvatar(
            radius: 34,
            backgroundColor: cs.primaryContainer,
            child: Icon(icon, size: 34, color: cs.onPrimaryContainer)),
        const SizedBox(height: 16),
        Text(title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4)),
        if (action != null) ...[const SizedBox(height: 18), action!],
      ]),
    );
  }
}

/// "low / medium / high confidence" (how many scans support a finding).
class ConfidenceChip extends StatelessWidget {
  final String? level;
  final int? n;
  const ConfidenceChip({super.key, required this.level, this.n});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = switch (level) {
      'high' => Colors.green,
      'medium' => Colors.orange,
      _ => cs.outline,
    };
    final dots = switch (level) { 'high' => 3, 'medium' => 2, _ => 1 };
    return Tooltip(
      message:
          'Confidence from the number of scans behind this finding (1 low, 2-3 medium, 4+ high)',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++)
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: i < dots ? c : c.withAlpha(50)),
          ),
        const SizedBox(width: 4),
        Text('${level ?? 'low'}${n != null ? ' · n=$n' : ''}',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

/// Section heading inside long scrolling pages.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.subtitle, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800)),
              if (subtitle != null)
                Text(subtitle!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13)),
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Coloured dot + label for a scan type.
Color tagColor(String? tag) => switch (tag) {
      'Baseline' => const Color(0xFF2E7D32),
      'Post-Meal' => const Color(0xFFE2570B),
      'Post-Intervention' ||
      'Post-Vajrasana' ||
      'Pre-Yoga' =>
        const Color(0xFF5B5FC7),
      'Post-Exercise' => const Color(0xFF00838F),
      _ => const Color(0xFF8D6E63),
    };

IconData tagIcon(String? tag) => switch (tag) {
      'Baseline' => Icons.flag_outlined,
      'Post-Meal' => Icons.restaurant,
      'Post-Intervention' ||
      'Post-Vajrasana' ||
      'Pre-Yoga' =>
        Icons.self_improvement,
      'Post-Exercise' => Icons.directions_run,
      'Caffeine' => Icons.coffee_outlined,
      'Stress' => Icons.bolt,
      'Poor-Sleep' => Icons.bedtime_outlined,
      _ => Icons.favorite_border,
    };
