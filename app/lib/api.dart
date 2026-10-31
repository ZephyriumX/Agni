import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'config.dart';

const scanTags = ['Baseline', 'Post-Meal', 'Post-Vajrasana', 'Caffeine', 'Stress', 'Poor-Sleep', 'Pre-Yoga'];
const contextTags = ['Caffeine', 'Stress', 'Poor-Sleep'];

enum ApiErrorKind { timeout, unreachable, unauthorized, rejected, server, other }

class ApiError implements Exception {
  final ApiErrorKind kind;
  final String message;
  final String? code;
  final int? status;
  ApiError(this.kind, this.message, {this.code, this.status});

  /// True when retrying the same upload later may succeed (nothing was rejected by the server).
  bool get retryable =>
      kind == ApiErrorKind.timeout ||
      kind == ApiErrorKind.unreachable ||
      (kind == ApiErrorKind.server && (status == 503 || status == 502 || status == 504));

  @override
  String toString() => message;
}

class DiagStep {
  final String name;
  final bool ok;
  final String detail;
  DiagStep(this.name, this.ok, this.detail);
}

class Api {
  static const _short = Duration(seconds: 6);
  static const _long = Duration(seconds: 45);

  static String _hint(String base, Object e) {
    final host = Uri.tryParse(base)?.host ?? '';
    final lines = <String>['Cannot reach the server at $base.'];
    if (host == '10.0.2.2') {
      lines.add('10.0.2.2 only works inside the Android emulator. On a physical phone use '
          'http://127.0.0.1:8000 with "adb reverse tcp:8000 tcp:8000", or your PC\'s Wi-Fi IP.');
    } else if (host == '127.0.0.1' || host == 'localhost') {
      lines.add('Run on the PC (USB debugging on): adb reverse tcp:8000 tcp:8000');
    } else {
      lines.add('Check: server started with --host 0.0.0.0, phone and PC on the same Wi-Fi (no guest/AP '
          'isolation), Windows Firewall allows inbound TCP 8000 on the Private profile.');
    }
    lines.add('Details: $e');
    return lines.join('\n');
  }

  static Future<http.Response> _send(String method, String path,
      {Map<String, dynamic>? body, bool auth = true, Duration? timeout, Map<String, String>? extra}) async {
    final base = await AppConfig.baseUrl();
    final headers = <String, String>{'Content-Type': 'application/json', ...?extra};
    if (auth) {
      final t = await AppConfig.token();
      if (t != null) headers['Authorization'] = 'Bearer $t';
    }
    final uri = Uri.parse('$base$path');
    try {
      final Future<http.Response> f;
      if (method == 'GET') {
        f = http.get(uri, headers: headers);
      } else if (method == 'PATCH') {
        f = http.patch(uri, headers: headers, body: jsonEncode(body));
      } else {
        f = http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
      }
      return await f.timeout(timeout ?? _short);
    } on TimeoutException catch (e) {
      throw ApiError(ApiErrorKind.timeout, _hint(base, e));
    } on SocketException catch (e) {
      throw ApiError(ApiErrorKind.unreachable, _hint(base, e));
    } on http.ClientException catch (e) {
      throw ApiError(ApiErrorKind.unreachable, _hint(base, e));
    }
  }

  static dynamic _parse(http.Response r) {
    dynamic body;
    try {
      body = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    var detail = body is Map ? body['detail'] : null;
    if (detail is List) detail = detail.map((e) => e is Map ? e['msg'] : '$e').join('; ');
    final code = body is Map ? body['code'] as String? : null;
    final msg = detail is String ? detail : 'Server error ${r.statusCode}';
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw ApiError(ApiErrorKind.unauthorized, msg, status: r.statusCode, code: code);
    }
    if (r.statusCode == 422 || r.statusCode == 400 || r.statusCode == 404 || r.statusCode == 413) {
      throw ApiError(ApiErrorKind.rejected, msg, status: r.statusCode, code: code);
    }
    throw ApiError(ApiErrorKind.server, msg, status: r.statusCode, code: code);
  }

  // ---- session
  static Future<void> ensureRegistered({String? prakriti}) async {
    if (await AppConfig.token() != null) return;
    final key = await AppConfig.registrationKey();
    final r = await _send('POST', '/api/v1/auth/register',
        body: {if (prakriti != null) 'prakriti_type': prakriti},
        auth: false,
        extra: key.isEmpty ? null : {'X-Registration-Key': key});
    final j = Map<String, dynamic>.from(_parse(r));
    await AppConfig.saveCredentials(j['user_id'] as String, j['token'] as String);
  }

  static Future<Map<String, dynamic>> me() async {
    await ensureRegistered();
    return Map<String, dynamic>.from(_parse(await _send('GET', '/api/v1/me')));
  }

  static Future<void> setPrakriti(String p) async {
    await ensureRegistered();
    _parse(await _send('PATCH', '/api/v1/me', body: {'prakriti_type': p}));
  }

  /// Each layer reported separately: /health (process) != /ready (database+migrations) != auth.
  static Future<List<DiagStep>> diagnose() async {
    final steps = <DiagStep>[];
    final base = await AppConfig.baseUrl();
    steps.add(DiagStep('API address', true, base));
    try {
      final h = _parse(await _send('GET', '/health', auth: false));
      steps.add(DiagStep('Server reachable (/health)', true, 'v${h['version']} env=${h['env']} auth=${h['auth_mode']}'));
    } on ApiError catch (e) {
      steps.add(DiagStep('Server reachable (/health)', false, e.message));
      return steps;
    }
    try {
      _parse(await _send('GET', '/ready', auth: false));
      steps.add(DiagStep('Database + migrations (/ready)', true, 'ok'));
    } on ApiError catch (e) {
      steps.add(DiagStep('Database + migrations (/ready)', false, e.message));
      return steps;
    }
    try {
      final m = await me();
      steps.add(DiagStep('Your profile (/me)', true, 'user ${m['user_id']}'));
    } on ApiError catch (e) {
      steps.add(DiagStep('Your profile (/me)', false, e.message));
    }
    return steps;
  }

  // ---- scans
  static Future<Map<String, dynamic>> processScan(Map<String, dynamic> payload) async {
    await ensureRegistered();
    final r = await _send('POST', '/api/v1/scan/process', body: payload, timeout: _long);
    return Map<String, dynamic>.from(_parse(r));
  }

  static Future<Map<String, dynamic>> createMeal(String name) async {
    await ensureRegistered();
    return Map<String, dynamic>.from(_parse(await _send('POST', '/api/v1/meals', body: {'name': name})));
  }

  static Future<Map<String, dynamic>> scan(String id) async =>
      Map<String, dynamic>.from(_parse(await _send('GET', '/api/v1/scans/$id')));

  static Future<Map<String, dynamic>> report() async {
    await ensureRegistered();
    final uid = await AppConfig.userId();
    return Map<String, dynamic>.from(_parse(await _send('GET', '/api/v1/reports/$uid')));
  }

  static Future<Map<String, dynamic>> diary() async {
    await ensureRegistered();
    return Map<String, dynamic>.from(_parse(await _send('GET', '/api/v1/diary')));
  }
}
