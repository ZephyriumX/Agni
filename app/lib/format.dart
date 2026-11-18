/// Small formatting helpers (no intl dependency).
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec'
];

DateTime? parseTs(dynamic v) =>
    v is String ? DateTime.tryParse(v)?.toLocal() : null;

String two(int n) => n.toString().padLeft(2, '0');

String fmtTime(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

String fmtDate(DateTime d, {bool year = false}) =>
    '${d.day} ${_months[d.month - 1]}${year ? ' ${d.year}' : ''}';

String fmtDateTime(DateTime d) => '${fmtDate(d)}, ${fmtTime(d)}';

/// "Today", "Yesterday", "Mon 3 Nov", "3 Nov 2025".
String fmtDay(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7 && diff > 0) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${wd[d.weekday - 1]} ${fmtDate(d)}';
  }
  return fmtDate(d, year: d.year != n.year);
}

String ago(DateTime d, {DateTime? now}) {
  final s = (now ?? DateTime.now()).difference(d);
  if (s.inMinutes < 1) return 'just now';
  if (s.inMinutes < 60) return '${s.inMinutes} min ago';
  if (s.inHours < 24) return '${s.inHours} h ago';
  if (s.inDays < 30) return '${s.inDays} d ago';
  return fmtDate(d, year: true);
}

String num1(dynamic v, [int d = 1]) => v is num ? v.toStringAsFixed(d) : '—';

String signed(dynamic v, [int d = 1, String unit = '']) {
  if (v is! num) return '—';
  final s = v.toStringAsFixed(d);
  return '${v > 0 ? '+' : ''}$s$unit';
}

String pct(dynamic v, [int d = 0]) =>
    v is num ? '${v.toStringAsFixed(d)}%' : '—';

/// Friendly labels for server enums.
String tagLabel(String? t) => switch (t) {
      'Baseline' => 'Baseline',
      'Post-Meal' => 'After meal',
      'Post-Intervention' => 'After intervention',
      'Post-Vajrasana' => 'After Vajrasana',
      'Post-Exercise' => 'After exercise',
      'Caffeine' => 'After caffeine',
      'Stress' => 'Stressed',
      'Poor-Sleep' => 'After poor sleep',
      'Pre-Yoga' => 'Before yoga',
      null => '—',
      String other => other,
    };

String capitalise(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('_', ' ');
