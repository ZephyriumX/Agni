import 'dart:math' as math;

/// Live acquisition monitor: finger presence (with hysteresis), pressure hints and a DISPLAY-ONLY
/// PPG/APG trace. Real metrics are computed server-side from the raw samples.
class SignalMonitor {
  final double windowSeconds;
  SignalMonitor({this.windowSeconds = 8});

  final List<double> t = [], r = [], g = [];
  double lastR = 0, lastG = 0, lastB = 0, lastSat = 0, lastDark = 0;
  bool finger = false;
  int _good = 0, _bad = 0;
  double? fingerSince;

  /// Candidate frame: bright red-dominant image (finger + torch). Thresholds are deliberately loose
  /// (phones differ a lot); live R/G/B values are shown on screen so they can be tuned from real logs.
  static bool looksLikeFinger(double r, double g, double b) =>
      r >= 60 && r >= 1.4 * g && r >= 1.8 * b;

  void add(double ts, double R, double G, double B, double sat, double dark) {
    lastR = R;
    lastG = G;
    lastB = B;
    lastSat = sat;
    lastDark = dark;
    if (looksLikeFinger(R, G, B)) {
      _good++;
      _bad = 0;
      if (!finger && _good >= 12) {
        finger = true;
        fingerSince = ts;
      }
    } else {
      _bad++;
      _good = 0;
      if (finger && _bad >= 15) {
        finger = false;
        fingerSince = null;
      }
    }
    t.add(ts);
    r.add(R);
    g.add(G);
    while (t.length > 2 && ts - t.first > windowSeconds) {
      t.removeAt(0);
      r.removeAt(0);
      g.removeAt(0);
    }
  }

  double stableSeconds(double now) =>
      finger && fingerSince != null ? now - fingerSince! : 0;

  /// R in a usable (unsaturated, bright enough) band.
  bool get exposureOk => lastR >= 110 && lastR <= 225 && lastSat < 0.2;

  List<double> _highpassSmoothInverted() {
    final n = r.length;
    if (n < 30) return const [];
    final fs = (n - 1) / (t.last - t.first);
    final w = math.max(3, (1.2 * fs).round());
    final out = List<double>.filled(n, 0);
    double run = 0;
    final pre = List<double>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      run += r[i];
      pre[i + 1] = run;
    }
    for (var i = 0; i < n; i++) {
      final a = math.max(0, i - w ~/ 2), b = math.min(n, i + w ~/ 2 + 1);
      out[i] = -(r[i] -
          (pre[b] - pre[a]) / (b - a)); // invert: more blood = lower intensity
    }
    final sm = List<double>.filled(n, 0);
    const k = 2;
    for (var i = 0; i < n; i++) {
      var s = 0.0;
      var c = 0;
      for (var j = math.max(0, i - k); j <= math.min(n - 1, i + k); j++) {
        s += out[j];
        c++;
      }
      sm[i] = s / c;
    }
    return sm;
  }

  List<double> displayPpg() => _highpassSmoothInverted();

  List<double> displayApg() {
    final p = _highpassSmoothInverted();
    if (p.length < 5) return const [];
    final out = List<double>.filled(p.length, 0);
    for (var i = 1; i < p.length - 1; i++) {
      out[i] = p[i + 1] - 2 * p[i] + p[i - 1];
    }
    return out;
  }

  /// Pulse amplitude relative to DC over the last ~3 s.
  double perfusion() {
    final p = _highpassSmoothInverted();
    if (p.length < 60 || lastR <= 0) return 0;
    final tail = p.sublist(math.max(0, p.length - 180));
    final mn = tail.reduce(math.min), mx = tail.reduce(math.max);
    return (mx - mn) / lastR;
  }

  /// Plain-language coaching (PRD risk mitigation: pressure sensitivity).
  String? hint() {
    if (!finger)
      return 'Cover the rear camera AND the flash fully with your fingertip.';
    if (lastSat > 0.2 || lastR > 235)
      return 'Image too bright - adjusting exposure, hold still.';
    if (lastR < 110)
      return 'Signal dim - adjusting exposure, keep the finger flat.';
    final pf = perfusion();
    if (r.length > 120 && pf < 0.0008)
      return 'Pulse is very weak: press LIGHTER and keep still.';
    return null;
  }
}
