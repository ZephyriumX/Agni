import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'capture_validation.dart';
import 'config.dart';

/// Scan types. "Post-Intervention" carries an [interventionTypes] value; "Post-Meal" can carry a meal.
const scanTags = [
  'Baseline',
  'Post-Meal',
  'Post-Intervention',
  'Post-Vajrasana',
  'Post-Exercise',
  'Caffeine',
  'Stress',
  'Poor-Sleep',
  'Pre-Yoga',
];
const contextTags = [
  'Caffeine',
  'Stress',
  'Poor-Sleep',
  'Fasting',
  'Alcohol',
  'Unwell',
  'Menstruation'
];
const interventionTypes = [
  'Vajrasana',
  'Sitali Pranayama',
  'Ginger Water / Pawanmuktasana',
  'Deep Breathing',
  'Meditation',
  'Walk',
  'Yoga',
  'Other',
];
const mealTypes = ['breakfast', 'lunch', 'dinner', 'snack', 'drink'];
const mealDescriptors = [
  'spicy',
  'fried',
  'sweet',
  'heavy',
  'light',
  'dairy',
  'caffeinated',
  'home-cooked',
  'outside',
  'raw',
  'late',
];

enum ApiErrorKind {
  timeout,
  unreachable,
  unauthorized,
  rejected,
  conflict,
  server,
  other
}

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
      (kind == ApiErrorKind.server &&
          (status == 503 || status == 502 || status == 504));

  @override
  String toString() => message;
}

class DiagStep {
  final String name;
  final bool ok;
  final String detail;
  DiagStep(this.name, this.ok, this.detail);
}

/// Result of sign-up / login / recovery.
class AuthResult {
  final String userId;
  final String token;
  final String? recoveryCode;
  final Map<String, dynamic> user;
  AuthResult(this.userId, this.token, this.recoveryCode, this.user);

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
      j['user_id'] as String,
      j['token'] as String,
      j['recovery_code'] as String?,
      Map<String, dynamic>.from(
          (j['user'] ?? const <String, dynamic>{}) as Map));
}

class Api {
  static const _short = Duration(seconds: 20);
  static const _long = Duration(seconds: 90);

  /// Called when an authenticated request is answered 401 (session expired / signed out elsewhere).
  static void Function()? onUnauthorized;

  static String _hint(String base, Object e) {
    final host = Uri.tryParse(base)?.host ?? '';
    final lines = <String>['Cannot reach the server at $base.'];
    if (host == '10.0.2.2') {
      lines.add(
          '10.0.2.2 only works inside the Android emulator. On a real phone use your cloud server address '
          '(https://...) in Server settings.');
    } else if (host == '127.0.0.1' || host == 'localhost') {
      lines.add(
          '127.0.0.1 only works with a USB cable and "adb reverse tcp:8000 tcp:8000" (or in a simulator). '
          'For wireless use, enter your cloud or tunnel https address in Server settings.');
    } else if (base.startsWith('https://')) {
      lines.add(
          'Check that the phone has internet. Free cloud servers sleep when idle and can take up to a minute '
          'to wake: wait a moment and retry.');
    } else {
      lines.add(
          'Check: server started with --host 0.0.0.0, phone and PC on the same Wi-Fi, firewall allows TCP 8000. '
          'For use outside your Wi-Fi, deploy the server (docs/REMOTE_ACCESS.md).');
    }
    lines.add('Details: $e');
    return lines.join('\n');
  }

  static Future<http.Response> _send(String method, String path,
      {Object? body,
      bool auth = true,
      Duration? timeout,
      Map<String, String>? extra,
      Map<String, String>? query}) async {
    final base = await AppConfig.baseUrl();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      ...?extra
    };
    if (auth) {
      final t = await AppConfig.token();
      if (t != null) headers['Authorization'] = 'Bearer $t';
    }
    var uri = Uri.parse('$base$path');
    if (query != null && query.isNotEmpty)
      uri = uri.replace(queryParameters: query);
    try {
      final Future<http.Response> f;
      switch (method) {
        case 'GET':
          f = http.get(uri, headers: headers);
        case 'PATCH':
          f = http.patch(uri,
              headers: headers,
              body: jsonEncode(body ?? const <String, dynamic>{}));
        case 'DELETE':
          f = http.delete(uri, headers: headers);
        default:
          f = http.post(uri,
              headers: headers,
              body: jsonEncode(body ?? const <String, dynamic>{}));
      }
      return await f.timeout(timeout ?? _short);
    } on TimeoutException catch (e) {
      throw ApiError(ApiErrorKind.timeout, _hint(base, e));
    } on SocketException catch (e) {
      throw ApiError(ApiErrorKind.unreachable, _hint(base, e));
    } on HandshakeException catch (e) {
      throw ApiError(ApiErrorKind.unreachable, _hint(base, e));
    } on http.ClientException catch (e) {
      throw ApiError(ApiErrorKind.unreachable, _hint(base, e));
    }
  }

  static dynamic _parse(http.Response r, {bool authed = true}) {
    dynamic body;
    try {
      body = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    var detail = body is Map ? body['detail'] : null;
    if (detail is List)
      detail = detail.map((e) => e is Map ? _pydanticMsg(e) : '$e').join('; ');
    final code = body is Map ? body['code'] as String? : null;
    final msg =
        detail is String ? _capitalise(detail) : 'Server error ${r.statusCode}';
    if (r.statusCode == 401 || r.statusCode == 403) {
      if (authed && r.statusCode == 401) onUnauthorized?.call();
      throw ApiError(ApiErrorKind.unauthorized, msg,
          status: r.statusCode, code: code);
    }
    if (r.statusCode == 409)
      throw ApiError(ApiErrorKind.conflict, msg, status: 409, code: code);
    if (r.statusCode == 422 ||
        r.statusCode == 400 ||
        r.statusCode == 404 ||
        r.statusCode == 413 ||
        r.statusCode == 429 ||
        r.statusCode == 501) {
      throw ApiError(ApiErrorKind.rejected, msg,
          status: r.statusCode, code: code);
    }
    throw ApiError(ApiErrorKind.server, msg, status: r.statusCode, code: code);
  }

  static String _pydanticMsg(Map e) {
    final loc = (e['loc'] is List)
        ? (e['loc'] as List).where((x) => x != 'body').join('.')
        : '';
    final m = '${e['msg'] ?? e}';
    return loc.isEmpty ? m : '$loc: $m';
  }

  static String _capitalise(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static Map<String, dynamic> _map(dynamic v) =>
      Map<String, dynamic>.from((v ?? const <String, dynamic>{}) as Map);
  static List<Map<String, dynamic>> _list(dynamic v) =>
      ((v ?? const <dynamic>[]) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  static Future<String> _device() async {
    try {
      return await AppConfig.deviceName();
    } catch (_) {
      return Platform.operatingSystem;
    }
  }

  // ------------------------------------------------------------------ server
  /// /health with a long timeout: free cloud instances can take ~60 s to wake from sleep.
  static Future<Map<String, dynamic>> wake() async =>
      _map(_parse(await _send('GET', '/health', auth: false, timeout: _long),
          authed: false));

  static Future<Map<String, dynamic>> authOptions() async =>
      _map(_parse(await _send('GET', '/api/v1/auth/options', auth: false),
          authed: false));

  /// Each layer reported separately: /health (process) != /ready (database+migrations) != account.
  static Future<List<DiagStep>> diagnose() async {
    final steps = <DiagStep>[];
    final base = await AppConfig.baseUrl();
    steps.add(DiagStep('Server address', true, base));
    final sw = Stopwatch()..start();
    try {
      final h = await wake();
      steps.add(DiagStep('Server reachable (/health)', true,
          'v${h['version']} · ${h['env']} · ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s'));
    } on ApiError catch (e) {
      steps.add(DiagStep('Server reachable (/health)', false, e.message));
      return steps;
    }
    try {
      _parse(await _send('GET', '/ready', auth: false), authed: false);
      steps.add(
          DiagStep('Database (/ready)', true, 'connected, schema up to date'));
    } on ApiError catch (e) {
      steps.add(DiagStep('Database (/ready)', false, e.message));
      return steps;
    }
    if (await AppConfig.token() != null) {
      try {
        final m = await me();
        steps.add(DiagStep(
            'Your account', true, '${m['email'] ?? 'device profile'}'));
      } on ApiError catch (e) {
        steps.add(DiagStep('Your account', false, e.message));
      }
    }
    return steps;
  }

  // ------------------------------------------------------------------ accounts
  static Map<String, String>? _regKeyHeader(String key) =>
      key.isEmpty ? null : {'X-Registration-Key': key};

  static Future<AuthResult> signup(
      String email, String password, String name) async {
    final key = await AppConfig.registrationKey();
    final r = await _send('POST', '/api/v1/auth/signup',
        body: {
          'email': email.trim(),
          'password': password,
          'display_name': name.trim(),
          'device_name': await _device(),
        },
        auth: false,
        extra: _regKeyHeader(key));
    return AuthResult.fromJson(_map(_parse(r, authed: false)));
  }

  static Future<AuthResult> login(String email, String password) async {
    final r = await _send('POST', '/api/v1/auth/login',
        body: {
          'email': email.trim(),
          'password': password,
          'device_name': await _device()
        },
        auth: false);
    return AuthResult.fromJson(_map(_parse(r, authed: false)));
  }

  /// Turn an old anonymous device profile (v0.x) into an e-mail account, keeping its data.
  static Future<AuthResult> upgrade(
      String email, String password, String name) async {
    final r = await _send('POST', '/api/v1/auth/upgrade', body: {
      'email': email.trim(),
      'password': password,
      'display_name': name.trim(),
      'device_name': await _device(),
    });
    return AuthResult.fromJson(_map(_parse(r)));
  }

  static Future<AuthResult> recover(
      String email, String code, String newPassword) async {
    final r = await _send('POST', '/api/v1/auth/recover',
        body: {
          'email': email.trim(),
          'recovery_code': code.trim(),
          'new_password': newPassword,
          'device_name': await _device(),
        },
        auth: false);
    return AuthResult.fromJson(_map(_parse(r, authed: false)));
  }

  static Future<void> forgot(String email) async => _parse(
      await _send('POST', '/api/v1/auth/forgot',
          body: {'email': email.trim()}, auth: false),
      authed: false);

  static Future<AuthResult> resetWithCode(
      String email, String code, String newPassword) async {
    final r = await _send('POST', '/api/v1/auth/reset',
        body: {
          'email': email.trim(),
          'code': code.trim(),
          'new_password': newPassword,
          'device_name': await _device(),
        },
        auth: false);
    return AuthResult.fromJson(_map(_parse(r, authed: false)));
  }

  /// Revokes this device's session on the server. Never throws: signing out locally must work offline.
  static Future<void> logout() async {
    try {
      await _send('POST', '/api/v1/auth/logout',
          timeout: const Duration(seconds: 8));
    } catch (_) {}
  }

  static Future<int> logoutAll() async =>
      (_map(_parse(await _send('POST', '/api/v1/auth/logout-all')))['revoked']
              as num?)
          ?.toInt() ??
      0;

  static Future<List<Map<String, dynamic>>> sessions() async =>
      _list(_parse(await _send('GET', '/api/v1/auth/sessions')));

  static Future<int> changePassword(String current, String next) async {
    final j = _map(_parse(await _send('POST', '/api/v1/auth/change-password',
        body: {'current_password': current, 'new_password': next})));
    return (j['other_sessions_signed_out'] as num?)?.toInt() ?? 0;
  }

  static Future<String> newRecoveryCode(String password) async =>
      _map(_parse(await _send('POST', '/api/v1/auth/recovery-code',
          body: {'password': password})))['recovery_code'] as String;

  static Future<void> deleteAccount({String? password}) async =>
      _parse(await _send('POST', '/api/v1/me/delete',
          body: password == null
              ? {'confirm': 'DELETE'}
              : {'password': password}));

  // ------------------------------------------------------------------ profile
  static Future<Map<String, dynamic>> me() async =>
      _map(_parse(await _send('GET', '/api/v1/me')));

  /// Partial update: only the keys given are changed.
  static Future<Map<String, dynamic>> updateProfile(
          Map<String, dynamic> fields) async =>
      _map(_parse(await _send('PATCH', '/api/v1/me', body: fields)));

  static Future<void> setPrakriti(String p) async =>
      updateProfile({'prakriti_type': p});

  // ------------------------------------------------------------------ scans
  static Future<Map<String, dynamic>> processScan(
      Map<String, dynamic> payload) async {
    final r = await _send('POST', '/api/v1/scan/process',
        body: payload, timeout: _long);
    return _map(_parse(r));
  }

  /// Server-side FPS/timing thresholds. Public endpoint; on any failure the bundled defaults (identical to
  /// the backend defaults) are used so scanning keeps working offline.
  static Future<CaptureConfig> captureConfig() async {
    try {
      final r = await _send('GET', '/api/v1/capture-config',
          auth: false, timeout: const Duration(seconds: 4));
      return CaptureConfig.fromJson(_map(_parse(r, authed: false)));
    } catch (_) {
      return CaptureConfig.defaults;
    }
  }

  static Future<List<Map<String, dynamic>>> scans(
          {String? tag, int limit = 300}) async =>
      _list(_parse(await _send('GET', '/api/v1/scans',
          query: {'limit': '$limit', if (tag != null) 'tag': tag})));

  static Future<Map<String, dynamic>> scan(String id) async =>
      _map(_parse(await _send('GET', '/api/v1/scans/$id')));

  static Future<void> deleteScan(String id) async =>
      _parse(await _send('DELETE', '/api/v1/scans/$id'));

  static Future<Map<String, dynamic>> compare(String baselineId, String testId,
          {String? intervention}) async =>
      _map(_parse(await _send('POST', '/api/v1/scan/compare', body: {
        'baseline_scan_id': baselineId,
        'test_scan_id': testId,
        if (intervention != null) 'intervention_type': intervention,
      })));

  static Future<Map<String, dynamic>> report() async =>
      _map(_parse(await _send('GET', '/api/v1/report')));

  static Future<Map<String, dynamic>> analytics({int days = 90}) async =>
      _map(_parse(await _send('GET', '/api/v1/analytics',
          timeout: _long,
          query: {
            'days': '$days',
            'tz_offset_min': '${DateTime.now().timeZoneOffset.inMinutes}'
          })));

  // ------------------------------------------------------------------ meals
  static Future<Map<String, dynamic>> createMeal(String name,
          {String? mealType,
          List<String> descriptors = const [],
          String? notes}) async =>
      _map(_parse(await _send('POST', '/api/v1/meals', body: {
        'name': name,
        if (mealType != null) 'meal_type': mealType,
        'descriptors': descriptors,
        if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      })));

  static Future<List<Map<String, dynamic>>> meals() async =>
      _list(_parse(await _send('GET', '/api/v1/meals')));

  static Future<void> deleteMeal(String id) async =>
      _parse(await _send('DELETE', '/api/v1/meals/$id'));
}
