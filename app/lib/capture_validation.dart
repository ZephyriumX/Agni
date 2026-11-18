/// Client-side capture-timing validation. A faithful port of backend/capture_validation.py.
///
/// The SERVER is authoritative (it holds the live config and also judges signal quality). This port
/// exists so the scan screen can show diagnostics immediately and avoid uploading a recording that is
/// certain to be rejected. Both implementations are checked against the same golden vectors
/// (docs/capture_validation_vectors.json) so they cannot silently drift apart.
///
/// Timing PASS/WARNING/FAIL says nothing about signal quality (SQI): that is judged separately on the
/// server and a failed SQI fails the scan whatever the fps. All numbers are initial engineering
/// parameters, not clinically validated limits.
library;

import 'dart:math' as math;

enum CaptureStatus { pass, warning, fail }

String statusLabel(CaptureStatus s) => switch (s) {
      CaptureStatus.pass => 'PASS',
      CaptureStatus.warning => 'WARNING',
      CaptureStatus.fail => 'FAIL',
    };

CaptureStatus? statusFromString(String? s) => switch (s) {
      'PASS' => CaptureStatus.pass,
      'WARNING' => CaptureStatus.warning,
      'FAIL' => CaptureStatus.fail,
      _ => null,
    };

class CaptureConfig {
  final double targetFps, preferredMinFps, hardMinFps, fpsTolerance;
  final double passMaxDropRatio, hardMaxDropRatio;
  final double passMaxGapS, hardMaxGapS;
  final double passMaxJitterCv, hardMaxJitterCv;
  final double windowS, passMaxLowWindowFraction, hardMaxLowWindowFraction;
  final double minDurationS, recommendedDurationS, maxPlausibleFps;

  const CaptureConfig({
    this.targetFps = 60,
    this.preferredMinFps = 58,
    this.hardMinFps = 55,
    this.fpsTolerance = 0.25,
    this.passMaxDropRatio = 0.03,
    this.hardMaxDropRatio = 0.05,
    this.passMaxGapS = 0.10,
    this.hardMaxGapS = 0.15,
    this.passMaxJitterCv = 0.10,
    this.hardMaxJitterCv = 0.20,
    this.windowS = 2.0,
    this.passMaxLowWindowFraction = 0.02,
    this.hardMaxLowWindowFraction = 0.10,
    this.minDurationS = 15.0,
    this.recommendedDurationS = 30.0,
    this.maxPlausibleFps = 1000.0,
  });

  /// Bundled defaults, identical to the backend defaults. Used when the server config is unavailable.
  static const defaults = CaptureConfig();

  /// Parses GET /api/v1/capture-config. Unknown/missing keys fall back to the defaults.
  factory CaptureConfig.fromJson(Map<String, dynamic> j) {
    double g(String k, double d) =>
        (j[k] is num) ? (j[k] as num).toDouble() : d;
    const d = CaptureConfig.defaults;
    return CaptureConfig(
      targetFps: g('target_fps', d.targetFps),
      preferredMinFps: g('preferred_min_fps', d.preferredMinFps),
      hardMinFps: g('hard_min_fps', d.hardMinFps),
      fpsTolerance: g('fps_tolerance', d.fpsTolerance),
      passMaxDropRatio: g('pass_max_drop_ratio', d.passMaxDropRatio),
      hardMaxDropRatio: g('hard_max_drop_ratio', d.hardMaxDropRatio),
      passMaxGapS: g('pass_max_gap_s', d.passMaxGapS),
      hardMaxGapS: g('hard_max_gap_s', d.hardMaxGapS),
      passMaxJitterCv: g('pass_max_jitter_cv', d.passMaxJitterCv),
      hardMaxJitterCv: g('hard_max_jitter_cv', d.hardMaxJitterCv),
      windowS: g('window_s', d.windowS),
      passMaxLowWindowFraction:
          g('pass_max_low_window_fraction', d.passMaxLowWindowFraction),
      hardMaxLowWindowFraction:
          g('hard_max_low_window_fraction', d.hardMaxLowWindowFraction),
      minDurationS: g('min_duration_s', d.minDurationS),
      recommendedDurationS: g('recommended_duration_s', d.recommendedDurationS),
      maxPlausibleFps: g('max_plausible_fps', d.maxPlausibleFps),
    );
  }

  /// Integer fps values handed to the native camera layer (it holds no thresholds of its own).
  int get nativeTargetFps => targetFps.round();
  int get nativeMinFps => hardMinFps.floor();
}

class CaptureReason {
  final String code;
  final CaptureStatus severity; // warning or fail
  final String message;
  const CaptureReason(this.code, this.severity, this.message);
}

class CaptureReport {
  final CaptureStatus status;
  final List<CaptureReason> reasons;
  final bool timestampsValid;
  final double fsMean, fsMedian, effectiveFs, dropRatio, maxGapS, jitterCv;
  final double minWindowFps, lowWindowFraction, durationS;
  final int nSamples, missingFrames;

  const CaptureReport({
    required this.status,
    required this.reasons,
    required this.timestampsValid,
    this.fsMean = 0,
    this.fsMedian = 0,
    this.effectiveFs = 0,
    this.dropRatio = 0,
    this.maxGapS = 0,
    this.jitterCv = 0,
    this.minWindowFps = 0,
    this.lowWindowFraction = 0,
    this.durationS = 0,
    this.nSamples = 0,
    this.missingFrames = 0,
  });

  Set<String> get codes => {for (final r in reasons) r.code};

  /// One line per reason, for the diagnostics panel.
  List<String> get messages => [for (final r in reasons) r.message];

  /// Plain-language headline for the status.
  String get headline => switch (status) {
        CaptureStatus.pass => 'Accepted: frame timing is good',
        CaptureStatus.warning => 'Accepted with minor frame-rate variation',
        CaptureStatus.fail => 'Rejected: frame timing is not good enough',
      };
}

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
}

// first index i with a[i] >= x (numpy searchsorted side='left')
int _lowerBound(List<double> a, double x) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (a[mid] < x) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

String _pct(double v, [int d = 1]) => '${(v * 100).toStringAsFixed(d)}%';

CaptureReport _failed(String code, String msg, {int n = 0}) => CaptureReport(
    status: CaptureStatus.fail,
    reasons: [CaptureReason(code, CaptureStatus.fail, msg)],
    timestampsValid: false,
    nSamples: n);

/// Judges a capture from its sensor timestamps (seconds). Mirrors evaluate_timestamps() in Python.
CaptureReport evaluateTimestamps(List<double> t,
    [CaptureConfig cfg = CaptureConfig.defaults]) {
  if (t.length < 10) {
    return _failed('timestamps_missing',
        'Timestamps are missing or too few to measure frame timing.');
  }
  if (t.any((x) => !x.isFinite)) {
    return _failed('timestamps_invalid',
        'Timestamps contain invalid (NaN/infinite) values.');
  }
  final dt = <double>[for (var i = 1; i < t.length; i++) t[i] - t[i - 1]];
  final bad = dt.where((d) => d <= 0).length;
  if (bad > 0) {
    return _failed(
        'timestamps_not_monotonic',
        'Timestamps are not strictly increasing ($bad duplicate/out-of-order frames). '
            'The camera clock cannot be trusted for this recording.',
        n: t.length);
  }
  final med = _median(dt);
  final duration = t.last - t.first;
  final fsMean = (t.length - 1) / duration;
  final fsMedian = 1.0 / med;
  if (fsMedian > cfg.maxPlausibleFps || fsMean > cfg.maxPlausibleFps) {
    return _failed('timestamps_implausible',
        'Timestamps imply ${fsMean.toStringAsFixed(0)} fps, which is implausible; they are probably not in seconds.',
        n: t.length);
  }
  final mad = _median([for (final d in dt) (d - med).abs()]);
  final jitterCv = 1.4826 * mad / med;
  var missing = 0;
  for (final d in dt) {
    if (d > 1.5 * med) missing += math.max((d / med).round() - 1, 0);
  }
  final dropRatio = missing / (t.length + missing);
  final maxGap = dt.reduce(math.max);

  final win = cfg.windowS;
  var nWin = 0, low = 0;
  var minWin = fsMean;
  if (duration >= win) {
    final stop = t.last - win + 1e-9;
    final step = win / 2.0;
    final slack = math.max(cfg.fpsTolerance,
        1.0 / win); // a window holds whole frames: resolves to 1/window_s
    minWin = double.infinity;
    for (var k = 0;; k++) {
      final s = t.first + k * step;
      if (s >= stop) break;
      final w = (_lowerBound(t, s + win) - _lowerBound(t, s)) / win;
      nWin++;
      if (w + slack < cfg.hardMinFps) low++;
      if (w < minWin) minWin = w;
    }
  }
  final lowFrac = nWin > 0 ? low / nWin : 0.0;

  final reasons = <CaptureReason>[];
  void add(String c, CaptureStatus s, String m) =>
      reasons.add(CaptureReason(c, s, m));
  final eff = math.min(fsMean, fsMedian) + cfg.fpsTolerance;
  final rawEff = math.min(fsMean, fsMedian);
  if (eff < cfg.hardMinFps) {
    add('fps_too_low', CaptureStatus.fail,
        'Camera delivered ${rawEff.toStringAsFixed(1)} fps, below the ${cfg.hardMinFps.toStringAsFixed(0)} fps minimum.');
  } else if (eff < cfg.preferredMinFps) {
    add(
        'fps_below_preferred',
        CaptureStatus.warning,
        'Camera delivered ${rawEff.toStringAsFixed(1)} fps (preferred ${cfg.preferredMinFps.toStringAsFixed(0)}+, '
            'minimum ${cfg.hardMinFps.toStringAsFixed(0)}).');
  }
  if (dropRatio > cfg.hardMaxDropRatio) {
    add('too_many_drops', CaptureStatus.fail,
        '${_pct(dropRatio)} of frames were dropped (limit ${_pct(cfg.hardMaxDropRatio, 0)}).');
  } else if (dropRatio > cfg.passMaxDropRatio) {
    add('some_drops', CaptureStatus.warning,
        '${_pct(dropRatio)} of frames were dropped.');
  }
  if (maxGap > cfg.hardMaxGapS) {
    add(
        'long_gap',
        CaptureStatus.fail,
        'Longest gap between frames was ${(maxGap * 1000).toStringAsFixed(0)} ms '
            '(limit ${(cfg.hardMaxGapS * 1000).toStringAsFixed(0)} ms).');
  } else if (maxGap > cfg.passMaxGapS) {
    add('gap', CaptureStatus.warning,
        'Longest gap between frames was ${(maxGap * 1000).toStringAsFixed(0)} ms.');
  }
  if (jitterCv > cfg.hardMaxJitterCv) {
    add('unstable_intervals', CaptureStatus.fail,
        'Frame intervals are too irregular (variability ${_pct(jitterCv, 0)}).');
  } else if (jitterCv > cfg.passMaxJitterCv) {
    add('jittery_intervals', CaptureStatus.warning,
        'Frame intervals are somewhat irregular (variability ${_pct(jitterCv, 0)}).');
  }
  if (lowFrac > cfg.hardMaxLowWindowFraction) {
    add(
        'fps_fluctuates',
        CaptureStatus.fail,
        'Frame rate dropped below ${cfg.hardMinFps.toStringAsFixed(0)} fps for ${_pct(lowFrac, 0)} of the recording '
            '(lowest ${minWin.toStringAsFixed(0)} fps over ${cfg.windowS.toStringAsFixed(0)} s).');
  } else if (lowFrac > cfg.passMaxLowWindowFraction) {
    add(
        'fps_dips',
        CaptureStatus.warning,
        'Frame rate briefly dipped below ${cfg.hardMinFps.toStringAsFixed(0)} fps '
            '(lowest ${minWin.toStringAsFixed(0)} fps over ${cfg.windowS.toStringAsFixed(0)} s).');
  }
  if (duration < cfg.minDurationS) {
    add('too_short', CaptureStatus.fail,
        'Capture lasted ${duration.toStringAsFixed(1)} s; at least ${cfg.minDurationS.toStringAsFixed(0)} s is required.');
  } else if (duration < cfg.recommendedDurationS) {
    add('short', CaptureStatus.warning,
        'Capture lasted ${duration.toStringAsFixed(1)} s; ${cfg.recommendedDurationS.toStringAsFixed(0)} s+ is recommended.');
  }

  final status = reasons.any((r) => r.severity == CaptureStatus.fail)
      ? CaptureStatus.fail
      : (reasons.isNotEmpty ? CaptureStatus.warning : CaptureStatus.pass);
  return CaptureReport(
    status: status,
    reasons: reasons,
    timestampsValid: true,
    fsMean: fsMean,
    fsMedian: fsMedian,
    effectiveFs: fsMean,
    dropRatio: dropRatio,
    maxGapS: maxGap,
    jitterCv: jitterCv,
    minWindowFps: minWin,
    lowWindowFraction: lowFrac,
    durationS: duration,
    nSamples: t.length,
    missingFrames: missing,
  );
}

/// Final scan status. Timing and SQI are independent gates; FAIL on either is FAIL.
/// A timing PASS never rescues a failed SQI. Unverified timing (null) is never a plain PASS.
CaptureStatus combineStatus(CaptureStatus? timing, bool sqiPassed) {
  if (!sqiPassed || timing == CaptureStatus.fail) return CaptureStatus.fail;
  return timing == CaptureStatus.pass
      ? CaptureStatus.pass
      : CaptureStatus.warning;
}
