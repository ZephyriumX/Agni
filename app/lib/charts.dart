import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'format.dart';

/// One plotted point.
class ChartPoint {
  final DateTime t;
  final double v;
  final Color color;
  final bool emphasis; // drawn larger (e.g. baselines)
  const ChartPoint(this.t, this.v, this.color, {this.emphasis = false});
}

/// Time-series chart: points coloured by scan type, an optional personal-normal band (mean ± SD), an optional
/// baseline line (rolling mean of baselines). Plain CustomPainter: no chart package needed.
class TrendChart extends StatelessWidget {
  final List<ChartPoint> points;
  final List<ChartPoint> line;
  final double? bandLow, bandHigh, mean;
  final String unit;
  final int decimals;
  final double height;
  const TrendChart({
    super.key,
    required this.points,
    this.line = const [],
    this.bandLow,
    this.bandHigh,
    this.mean,
    this.unit = '',
    this.decimals = 0,
    this.height = 190,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _TrendPainter(
            points,
            line,
            bandLow,
            bandHigh,
            mean,
            unit,
            decimals,
            cs.onSurfaceVariant,
            cs.outlineVariant,
            cs.primary,
            Theme.of(context).brightness == Brightness.dark),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<ChartPoint> pts, line;
  final double? lo, hi, mean;
  final String unit;
  final int dec;
  final Color text, grid, accent;
  final bool dark;
  _TrendPainter(this.pts, this.line, this.lo, this.hi, this.mean, this.unit,
      this.dec, this.text, this.grid, this.accent, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0, right = 8.0, top = 8.0, bottom = 22.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    if (pts.isEmpty || w <= 0 || h <= 0) return;
    final vals = [...pts.map((p) => p.v), ...line.map((p) => p.v)];
    if (lo != null) vals.add(lo!);
    if (hi != null) vals.add(hi!);
    var vmin = vals.reduce(math.min), vmax = vals.reduce(math.max);
    if ((vmax - vmin).abs() < 1e-9) {
      vmin -= 1;
      vmax += 1;
    }
    final pad = (vmax - vmin) * 0.12;
    vmin -= pad;
    vmax += pad;
    final times = [...pts.map((p) => p.t), ...line.map((p) => p.t)];
    var t0 = times.reduce((a, b) => a.isBefore(b) ? a : b);
    var t1 = times.reduce((a, b) => a.isAfter(b) ? a : b);
    if (t1.difference(t0).inMinutes < 60) {
      t0 = t0.subtract(const Duration(hours: 12));
      t1 = t1.add(const Duration(hours: 12));
    }
    final span = t1.difference(t0).inSeconds.toDouble();
    double x(DateTime t) => left + w * (t.difference(t0).inSeconds / span);
    double y(double v) => top + h * (1 - (v - vmin) / (vmax - vmin));

    final gridP = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final ts = TextStyle(color: text, fontSize: 10);
    for (var i = 0; i <= 3; i++) {
      final v = vmin + (vmax - vmin) * i / 3;
      final yy = y(v);
      canvas.drawLine(Offset(left, yy), Offset(left + w, yy),
          gridP..color = grid.withAlpha(90));
      _text(canvas, v.toStringAsFixed(dec), Offset(2, yy - 6), ts, 40);
    }
    _text(canvas, fmtDate(t0), Offset(left, top + h + 6), ts, 80);
    _text(canvas, fmtDate(t1), Offset(left + w - 60, top + h + 6), ts, 60,
        align: TextAlign.right);

    if (lo != null && hi != null) {
      final band = Paint()..color = Colors.green.withAlpha(dark ? 45 : 32);
      canvas.drawRect(Rect.fromLTRB(left, y(hi!), left + w, y(lo!)), band);
    }
    if (mean != null) {
      final mp = Paint()
        ..color = Colors.green.withAlpha(150)
        ..strokeWidth = 1.2;
      _dashed(canvas, Offset(left, y(mean!)), Offset(left + w, y(mean!)), mp);
    }
    if (line.length >= 2) {
      final path = Path()..moveTo(x(line.first.t), y(line.first.v));
      for (final p in line.skip(1)) {
        path.lineTo(x(p.t), y(p.v));
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = accent.withAlpha(170)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    for (final p in pts) {
      final c = Offset(x(p.t), y(p.v));
      canvas.drawCircle(c, p.emphasis ? 5 : 4, Paint()..color = p.color);
      canvas.drawCircle(
          c,
          p.emphasis ? 5 : 4,
          Paint()
            ..color = dark ? Colors.black54 : Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
    }
  }

  void _dashed(Canvas c, Offset a, Offset b, Paint p) {
    const dash = 5.0, gap = 4.0;
    final len = (b - a).distance;
    final dir = (b - a) / len;
    var d = 0.0;
    while (d < len) {
      c.drawLine(a + dir * d, a + dir * math.min(d + dash, len), p);
      d += dash + gap;
    }
  }

  void _text(Canvas c, String s, Offset o, TextStyle st, double maxW,
      {TextAlign align = TextAlign.left}) {
    final tp = TextPainter(
        text: TextSpan(text: s, style: st),
        textDirection: TextDirection.ltr,
        textAlign: align)
      ..layout(maxWidth: maxW);
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => true;
}

/// Horizontal bar 0..100 with threshold tick (e.g. compatibility %, 70 % PRD threshold).
class PercentBar extends StatelessWidget {
  final double? value;
  final double threshold;
  const PercentBar({super.key, required this.value, this.threshold = 70});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = (value ?? 0).clamp(0, 100).toDouble();
    final c =
        v >= 85 ? Colors.green : (v >= threshold ? Colors.orange : cs.error);
    return LayoutBuilder(builder: (ctx, box) {
      final w = box.maxWidth;
      return SizedBox(
        height: 14,
        child: Stack(children: [
          Container(
              decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(7))),
          Container(
              width: w * v / 100,
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(7))),
          Positioned(
              left: w * threshold / 100 - 1,
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: cs.onSurface.withAlpha(120))),
        ]),
      );
    });
  }
}

/// Diverging bar around zero (e.g. change vs baseline). [good] = whether a positive value is good.
class DeltaBar extends StatelessWidget {
  final double value;
  final double scale; // |value| that fills half the bar
  final bool positiveIsGood;
  final bool neutral; // direction carries no good/bad meaning (e.g. heart rate)
  const DeltaBar(
      {super.key,
      required this.value,
      required this.scale,
      this.positiveIsGood = true,
      this.neutral = false});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final frac = (value.abs() / (scale <= 0 ? 1 : scale)).clamp(0.0, 1.0);
    final good = (value >= 0) == positiveIsGood;
    final c = value.abs() < 1e-9
        ? cs.outline
        : (neutral ? cs.primary : (good ? Colors.green : cs.error));
    return LayoutBuilder(builder: (ctx, box) {
      final half = box.maxWidth / 2;
      return SizedBox(
        height: 10,
        child: Stack(children: [
          Container(
              decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(5))),
          Positioned(
            left: value >= 0 ? half : half - half * frac,
            width: half * frac,
            top: 0,
            bottom: 0,
            child: Container(
                decoration: BoxDecoration(
                    color: c, borderRadius: BorderRadius.circular(5))),
          ),
          Positioned(
              left: half - 1,
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: cs.onSurface.withAlpha(140))),
        ]),
      );
    });
  }
}
