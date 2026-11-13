import 'dart:async';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ppg_camera/ppg_camera.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api.dart';
import 'capture_validation.dart';
import 'pending_queue.dart';
import 'result_view.dart';
import 'signal_monitor.dart';
import 'waveform.dart';

const scanSeconds = 35;

class ScanScreen extends StatefulWidget {
  final String initialTag;
  final String? compareTo; // e.g. the pre-Vajrasana scan id
  const ScanScreen({super.key, this.initialTag = 'Baseline', this.compareTo});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

enum Phase { init, blocked, ready, recording, uploading, done }

class _ScanScreenState extends State<ScanScreen> {
  final _mon = SignalMonitor();
  final _meal = TextEditingController();
  StreamSubscription<PpgBatch>? _sub;
  Phase _phase = Phase.init;
  late String _tag = widget.initialTag;
  final Set<String> _ctx = {};
  String _status = 'Starting camera…';
  String? _caps;
  String? _error;
  Map<String, dynamic>? _result;
  Map<String, dynamic>? _startInfo;
  int _iso = 0, _expNs = 0, _frameNs = 0;
  bool _locked = false;
  double _fpsLive = 0;
  int _fpsCount = 0;
  double _fpsT0 = 0;
  final _t = <double>[], _red = <double>[], _green = <double>[];
  double _recT0 = 0, _progress = 0, _lostSince = -1;
  double _now = 0;
  // capture validation / diagnostics
  CaptureConfig _cfg = CaptureConfig.defaults;
  CaptureReport? _capReport;
  PpgCapabilities? _capsObj;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final st = await Permission.camera.request();
    if (!st.isGranted) {
      _block('Camera permission is required to read your pulse.', null);
      return;
    }
    try {
      // thresholds come from the server (bundled defaults if it is unreachable); native code has none
      _cfg = await Api.captureConfig();
      final caps = await PpgCamera.capabilities(
          targetFps: _cfg.nativeTargetFps, minFps: _cfg.nativeMinFps);
      _capsObj = caps;
      if (!caps.meetsMinimum) {
        _block(
            'This phone\'s camera cannot reach the minimum of ${_cfg.hardMinFps.toStringAsFixed(0)} frames per second '
            'that the analysis needs. Scans are NOT run at a lower rate, and a slower stream is never relabelled '
            'as ${_cfg.targetFps.toStringAsFixed(0)} fps.',
            caps.describe());
        return;
      }
      _caps = caps.describe();
      _sub = PpgCamera.batches.listen(_onBatch,
          onError: (e) => _block('Camera stream error: $e', _caps));
      _startInfo = await PpgCamera.start(
          targetFps: _cfg.nativeTargetFps, minFps: _cfg.nativeMinFps);
      WakelockPlus.enable();
      if (!mounted) return;
      setState(() {
        _phase = Phase.ready;
        _status =
            'Camera running (${_startInfo!['width']}x${_startInfo!['height']}, '
            '${_startInfo!['manualExposure'] == true ? 'manual' : 'auto'} exposure).';
      });
    } on PlatformException catch (e) {
      _block('${e.code}: ${e.message}', _caps);
    } catch (e) {
      _block('Camera could not start: $e', _caps);
    }
  }

  void _block(String msg, String? caps) {
    if (!mounted) return;
    setState(() {
      _phase = Phase.blocked;
      _error = msg;
      _caps = caps ?? _caps;
    });
  }

  void _onBatch(PpgBatch b) {
    final f = b.frames;
    for (var i = 0; i < b.count; i++) {
      final o = i * 6;
      final ts = f[o];
      _now = ts;
      _mon.add(ts, f[o + 1], f[o + 2], f[o + 3], f[o + 4], f[o + 5]);
      if (_fpsT0 == 0) _fpsT0 = ts;
      _fpsCount++;
      if (ts - _fpsT0 >= 1.0) {
        _fpsLive = _fpsCount / (ts - _fpsT0);
        _fpsCount = 0;
        _fpsT0 = ts;
      }
      if (_phase == Phase.recording) {
        if (!_mon.finger) {
          if (_lostSince < 0) _lostSince = ts;
          if (ts - _lostSince > 0.6) {
            _abort('Finger lifted during the scan. Please try again.');
            return;
          }
        } else {
          _lostSince = -1;
        }
        _t.add(ts - _recT0);
        _red.add(f[o + 1]);
        _green.add(f[o + 2]);
        if (ts - _recT0 >= scanSeconds) {
          _finish();
          return;
        }
      }
    }
    _iso = b.iso;
    _expNs = b.exposureNs;
    _frameNs = b.frameDurationNs;
    _locked = b.locked;
    // lock exposure once the finger is stable and R is in the usable band
    if (_phase == Phase.ready &&
        !_locked &&
        _mon.stableSeconds(_now) > 2.0 &&
        _mon.exposureOk) {
      PpgCamera.setExposureLock(true);
    }
    if (_phase == Phase.recording)
      _progress = ((_now - _recT0) / scanSeconds).clamp(0.0, 1.0);
    if (mounted) setState(() {});
  }

  bool get _canStart =>
      _phase == Phase.ready &&
      _mon.finger &&
      _mon.stableSeconds(_now) > 2.0 &&
      _mon.exposureOk;

  void _start() {
    _t.clear();
    _red.clear();
    _green.clear();
    _recT0 = _now;
    _lostSince = -1;
    _progress = 0;
    setState(() {
      _phase = Phase.recording;
      _result = null;
      _status = 'Recording… stay still and breathe normally.';
    });
  }

  void _abort(String msg) {
    _t.clear();
    _red.clear();
    _green.clear();
    if (mounted)
      setState(() {
        _phase = Phase.ready;
        _progress = 0;
        _status = msg;
      });
  }

  Future<void> _finish() async {
    // Judge the REAL sensor timestamps first. A capture that is certain to be rejected is not uploaded.
    final rep = evaluateTimestamps(_t, _cfg);
    _capReport = rep;
    if (rep.status == CaptureStatus.fail) {
      await PpgCamera.stop();
      WakelockPlus.disable();
      _t.clear();
      _red.clear();
      _green.clear();
      _fail('${rep.headline}.\n${rep.messages.join('\n')}\n\n'
          'Tips: close other apps, let the phone cool down, keep your finger still, and scan again.');
      return;
    }
    setState(() {
      _phase = Phase.uploading;
      _status = 'Uploading and analysing…';
    });
    final payload = <String, dynamic>{
      'client_scan_id': const Uuid().v4(),
      'tag': _tag,
      'context': _ctx.toList(),
      if (widget.compareTo != null) 'compare_to': widget.compareTo,
      'timestamps': _t.map((x) => double.parse(x.toStringAsFixed(5))).toList(),
      'red': _red.map((x) => double.parse(x.toStringAsFixed(3))).toList(),
      'green': _green.map((x) => double.parse(x.toStringAsFixed(3))).toList(),
    };
    await PpgCamera
        .stop(); // torch off + camera released as soon as sampling is done
    WakelockPlus.disable();
    try {
      if (_tag == 'Post-Meal' && _meal.text.trim().isNotEmpty) {
        try {
          payload['meal_id'] =
              (await Api.createMeal(_meal.text.trim()))['meal_id'];
        } on ApiError catch (e) {
          if (!e.retryable)
            rethrow; // offline: the scan itself is still saved below, meal label skipped
        }
      }
      final res = await Api.processScan(payload);
      if (!mounted) return;
      setState(() {
        _result = res;
        _phase = Phase.done;
        _status = 'Done';
      });
    } on ApiError catch (e) {
      if (e.retryable || e.kind == ApiErrorKind.unauthorized) {
        await PendingQueue.add(payload);
        _fail(
            '${e.message}\n\nYour recording was SAVED on this phone and will upload automatically '
            'when the server is reachable (Home → pending uploads).');
      } else {
        _fail(e.message);
      }
    }
  }

  void _fail(String msg) {
    if (mounted)
      setState(() {
        _phase = Phase.done;
        _result = null;
        _error = msg;
        _status = 'Failed';
      });
  }

  @override
  void dispose() {
    _sub?.cancel();
    PpgCamera.stop();
    WakelockPlus.disable();
    _meal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = _phase == Phase.ready || _phase == Phase.recording;
    return Scaffold(
      appBar: AppBar(title: const Text('New scan')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_phase == Phase.blocked) _blocked(),
        if (_phase == Phase.init)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator())),
        if (live) ...[
          DropdownButtonFormField<String>(
            value: _tag,
            decoration: const InputDecoration(labelText: 'Scan context'),
            items: [
              for (final t in scanTags)
                DropdownMenuItem(value: t, child: Text(t))
            ],
            onChanged: _phase == Phase.recording
                ? null
                : (v) => setState(() => _tag = v!),
          ),
          if (_tag == 'Post-Meal')
            TextField(
                controller: _meal,
                decoration: const InputDecoration(
                    labelText: 'What did you eat? (for your diary)')),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final c in contextTags)
              FilterChip(
                label: Text(c),
                selected: _ctx.contains(c),
                onSelected: _phase == Phase.recording
                    ? null
                    : (s) => setState(() => s ? _ctx.add(c) : _ctx.remove(c)),
              ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Icon(_mon.finger ? Icons.check_circle : Icons.fingerprint,
                color: _mon.finger ? Colors.green : Colors.grey),
            const SizedBox(width: 8),
            Expanded(
                child: Text(_mon.hint() ??
                    (_canStart ? 'Good signal - ready.' : 'Hold still…'))),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 170,
            child: DecoratedBox(
              decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8)),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: CustomPaint(
                    painter: WaveformPainter(_mon.displayPpg(),
                        _mon.displayApg(), Colors.deepOrange, Colors.indigo),
                    size: Size.infinite),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
                'Top: PPG pulse wave   Bottom: APG (2nd derivative)   - display only; metrics are computed on the server',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          const SizedBox(height: 8),
          Text(_status),
          if (_phase == Phase.recording) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress),
            Text('${(scanSeconds * (1 - _progress)).ceil()} s left'),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _canStart ? _start : null,
            icon: const Icon(Icons.favorite),
            label: Text(_phase == Phase.recording
                ? 'Recording…'
                : 'Start $scanSeconds s scan'),
          ),
          if (_phase == Phase.recording)
            TextButton(
                onPressed: () => _abort('Scan cancelled.'),
                child: const Text('Cancel')),
          ExpansionTile(
            title: const Text('Capture diagnostics'),
            childrenPadding: const EdgeInsets.all(8),
            children: [
              _diagnostics(),
              SelectableText(
                  'fps (sensor timestamps): ${_fpsLive.toStringAsFixed(1)}\n'
                  'R/G/B: ${_mon.lastR.toStringAsFixed(0)}/${_mon.lastG.toStringAsFixed(0)}/${_mon.lastB.toStringAsFixed(0)}  '
                  'saturated: ${(_mon.lastSat * 100).toStringAsFixed(0)}%\n'
                  'exposure: ${(_expNs / 1e6).toStringAsFixed(2)} ms  ISO $_iso  frame ${(_frameNs / 1e6).toStringAsFixed(2)} ms  '
                  'locked: $_locked\n'
                  'perfusion: ${(_mon.perfusion() * 100).toStringAsFixed(3)} %\n${_caps ?? ''}',
                  style:
                      const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            ],
          ),
        ],
        if (_phase == Phase.uploading)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator())),
        if (_phase == Phase.done) ...[
          if (_capReport != null) _diagnostics(),
          if (_result != null)
            ResultView(result: _result!, onVajrasana: _openVajrasana),
          if (_result == null && _error != null)
            Card(
                color: Colors.red.shade50,
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(_error!))),
          const SizedBox(height: 12),
          OutlinedButton(
              onPressed: () => Navigator.pop(context, _result),
              child: const Text('Close')),
        ],
      ]),
    );
  }

  String get _platformName => switch (defaultTargetPlatform) {
        TargetPlatform.iOS => 'iOS (AVFoundation)',
        TargetPlatform.android => 'Android (Camera2)',
        _ => defaultTargetPlatform.name,
      };

  /// Capture diagnostics: what the camera actually did versus what was asked, and the timing verdict.
  Widget _diagnostics() {
    final rep = _capReport;
    final flash = _capsObj?.chosenHasFlash;
    final res = _result;
    final sqiOk = res == null ? null : (res['sqi'] as Map?)?['passed'] == true;
    final srv = statusFromString(res?['capture_status'] as String?);
    final timing = rep?.status ?? srv;
    String line(String k, String v) => '$k: $v';
    final rows = <String>[
      line('Platform', _platformName),
      line(
          'Camera',
          _startInfo == null
              ? '-'
              : 'id ${_startInfo!['cameraId']} '
                  '(${_startInfo!['width']}x${_startInfo!['height']}, ${_startInfo!['manualExposure'] == true ? 'manual' : 'auto'} exposure)'),
      line('Flash',
          flash == null ? 'unknown' : (flash ? 'available' : 'not available')),
      line('Target FPS', _cfg.targetFps.toStringAsFixed(0)),
      line('Minimum FPS',
          '${_cfg.hardMinFps.toStringAsFixed(0)} (preferred ${_cfg.preferredMinFps.toStringAsFixed(0)}+)'),
      line(
          'Actual FPS',
          rep != null
              ? rep.fsMean.toStringAsFixed(1)
              : '${_fpsLive.toStringAsFixed(1)} (live)'),
      if (rep != null && rep.timestampsValid) ...[
        line('Frame drops',
            '${(rep.dropRatio * 100).toStringAsFixed(1)}% (${rep.missingFrames} frames)'),
        line('Longest gap', '${(rep.maxGapS * 1000).toStringAsFixed(0)} ms'),
        line('Interval variability',
            '${(rep.jitterCv * 100).toStringAsFixed(1)}%'),
        line('Capture duration', '${rep.durationS.toStringAsFixed(1)} s'),
      ],
      line(
          'Capture status',
          timing == null
              ? (_phase == Phase.recording ? 'recording' : 'ready')
              : '${statusLabel(timing)}${rep != null ? ' - ${rep.headline}' : ''}'),
      if (sqiOk != null) line('Signal quality', sqiOk ? 'Pass' : 'Fail'),
      if (res?['final_status'] != null)
        line('Final result', '${res!['final_status']}'),
      if (rep != null) ...[for (final m in rep.messages) '  • $m'],
    ];
    final color = switch (timing) {
      CaptureStatus.pass => Colors.green.shade50,
      CaptureStatus.warning => Colors.amber.shade50,
      CaptureStatus.fail => Colors.red.shade50,
      null => Colors.grey.shade100,
    };
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: SelectableText(rows.join('\n'),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
      ),
    );
  }

  void _openVajrasana() {
    final id = _result?['scan_id'] as String?;
    Navigator.pop(context, {'vajrasana_for': id});
  }

  Widget _blocked() => Card(
        color: Colors.orange.shade50,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_error ?? 'Camera unavailable',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            if (_caps != null) ...[
              const SizedBox(height: 8),
              SelectableText(_caps!,
                  style:
                      const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            ],
            const SizedBox(height: 8),
            FilledButton(
                onPressed: () {
                  setState(() {
                    _phase = Phase.init;
                    _error = null;
                  });
                  _init();
                },
                child: const Text('Retry')),
          ]),
        ),
      );
}
