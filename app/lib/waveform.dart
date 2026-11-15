import 'package:flutter/material.dart';

class WaveformPainter extends CustomPainter {
  final List<double> ppg, apg;
  final Color ppgColor, apgColor;
  WaveformPainter(this.ppg, this.apg, this.ppgColor, this.apgColor);

  void _line(Canvas c, Rect r, List<double> v, Color col) {
    if (v.length < 2) return;
    var mn = v.reduce((a, b) => a < b ? a : b), mx = v.reduce((a, b) => a > b ? a : b);
    if (mx - mn < 1e-9) { mx = mn + 1; }
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = r.left + r.width * i / (v.length - 1);
      final y = r.bottom - r.height * ((v[i] - mn) / (mx - mn));
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    c.drawPath(path, Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 2);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height / 2 - 6;
    _line(canvas, Rect.fromLTWH(0, 2, size.width, h), ppg, ppgColor);
    _line(canvas, Rect.fromLTWH(0, size.height / 2 + 4, size.width, h), apg, apgColor);
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) => true;
}

/// Overlay of two ensemble-average APG beats (before vs after) from backend templates.
class BeforeAfterPainter extends CustomPainter {
  final List<double> before, after;
  BeforeAfterPainter(this.before, this.after);

  void _line(Canvas c, Size s, List<double> v, Color col) {
    if (v.length < 2) return;
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = s.width * i / (v.length - 1);
      final y = s.height / 2 - (s.height / 2 - 6) * v[i].clamp(-1.0, 1.0);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    c.drawPath(path, Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 2.5);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2),
        Paint()..color = Colors.grey.shade300);
    _line(canvas, size, before, Colors.grey.shade700);
    _line(canvas, size, after, Colors.deepOrange);
  }

  @override
  bool shouldRepaint(covariant BeforeAfterPainter old) => true;
}
