import 'package:flutter/material.dart';

import 'capture_validation.dart';

/// Agni-Pulse design system: one warm "ember" seed colour, Material 3, light + dark.
/// Only long-stable theme APIs are used so the app builds across Flutter versions.
class Brand {
  static const ember = Color(0xFFE2570B);
}

ThemeData buildTheme(Brightness brightness) {
  final scheme =
      ColorScheme.fromSeed(seedColor: Brand.ember, brightness: brightness);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final r14 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      titleTextStyle: TextStyle(
          color: scheme.onSurface, fontSize: 20, fontWeight: FontWeight.w700),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: r14,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48), shape: r14),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      height: 68,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
  );
}

/// Semantic colours for PASS / WARNING / FAIL (and "unknown"), readable in light and dark mode.
class StatusStyle {
  final Color bg, fg;
  final IconData icon;
  const StatusStyle(this.bg, this.fg, this.icon);

  static StatusStyle of(BuildContext context, CaptureStatus? s) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    switch (s) {
      case CaptureStatus.pass:
        return dark
            ? const StatusStyle(
                Color(0xFF1B3A1F), Color(0xFF9BE3A0), Icons.check_circle)
            : const StatusStyle(
                Color(0xFFE3F4E4), Color(0xFF1B5E20), Icons.check_circle);
      case CaptureStatus.warning:
        return dark
            ? const StatusStyle(Color(0xFF3D3214), Color(0xFFFFD36B),
                Icons.warning_amber_rounded)
            : const StatusStyle(Color(0xFFFFF3D6), Color(0xFF8A5A00),
                Icons.warning_amber_rounded);
      case CaptureStatus.fail:
        return dark
            ? const StatusStyle(
                Color(0xFF3F1A1A), Color(0xFFFFA8A8), Icons.cancel)
            : const StatusStyle(
                Color(0xFFFDE4E4), Color(0xFF9C1C1C), Icons.cancel);
      case null:
        return dark
            ? const StatusStyle(Color(0xFF2B2B2B), Color(0xFFCFCFCF),
                Icons.radio_button_unchecked)
            : const StatusStyle(Color(0xFFEDEDED), Color(0xFF555555),
                Icons.radio_button_unchecked);
    }
  }
}
