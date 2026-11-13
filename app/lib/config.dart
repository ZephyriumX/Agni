import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional build-time default:  flutter run --dart-define=API_BASE_URL=https://api.example.com
const _definedBaseUrl = String.fromEnvironment('API_BASE_URL');

class AppConfig {
  static const _secure = FlutterSecureStorage();

  static Future<bool> isPhysicalDevice() async {
    if (!Platform.isAndroid) return true;
    return (await DeviceInfoPlugin().androidInfo).isPhysicalDevice;
  }

  /// Emulator: 10.0.2.2 is the host PC. Physical phone: that address does NOT exist on your Wi-Fi (this is
  /// what produced "Connection timed out"). The default for a real phone is localhost + `adb reverse`.
  static Future<String> defaultBaseUrl() async {
    if (_definedBaseUrl.isNotEmpty) return _definedBaseUrl;
    return await isPhysicalDevice()
        ? 'http://127.0.0.1:8000'
        : 'http://10.0.2.2:8000';
  }

  static Future<String> baseUrl() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('baseUrl');
    if (saved != null && saved.isNotEmpty) {
      // a saved emulator-only address on a real phone can never work -> ignore it
      if (saved.contains('10.0.2.2') && await isPhysicalDevice())
        return defaultBaseUrl();
      return saved;
    }
    return defaultBaseUrl();
  }

  static Future<void> setBaseUrl(String v) async {
    var u = v.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.isNotEmpty && !u.startsWith('http://') && !u.startsWith('https://'))
      u = 'http://$u';
    await (await SharedPreferences.getInstance()).setString('baseUrl', u);
  }

  static Future<String> registrationKey() async =>
      (await _secure.read(key: 'regKey')) ?? '';
  static Future<void> setRegistrationKey(String v) =>
      _secure.write(key: 'regKey', value: v.trim());

  static Future<String?> token() => _secure.read(key: 'token');
  static Future<String?> userId() => _secure.read(key: 'userId');
  static Future<void> saveCredentials(String userId, String token) async {
    await _secure.write(key: 'userId', value: userId);
    await _secure.write(key: 'token', value: token);
  }

  static Future<void> clearCredentials() async {
    await _secure.delete(key: 'userId');
    await _secure.delete(key: 'token');
  }
}
