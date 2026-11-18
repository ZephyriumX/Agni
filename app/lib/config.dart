import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional build-time default:  flutter run --dart-define=API_BASE_URL=https://api.example.com
const _definedBaseUrl = String.fromEnvironment('API_BASE_URL');

class AppConfig {
  /// Server address baked into this build (flutter build apk --dart-define=API_BASE_URL=https://...), or ''.
  static String get builtInBaseUrl => _definedBaseUrl;

  static const _secure = FlutterSecureStorage();

  static Future<bool> isPhysicalDevice() async {
    if (Platform.isAndroid)
      return (await DeviceInfoPlugin().androidInfo).isPhysicalDevice;
    if (Platform.isIOS)
      return (await DeviceInfoPlugin().iosInfo).isPhysicalDevice;
    return true;
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

  /// The camera the user picked on the scan screen ("0", "0:2" ...). null = automatic.
  static Future<String?> cameraKey() async =>
      (await SharedPreferences.getInstance()).getString('cameraKey');
  static Future<void> setCameraKey(String? key) async {
    final p = await SharedPreferences.getInstance();
    if (key == null || key.isEmpty) {
      await p.remove('cameraKey');
    } else {
      await p.setString('cameraKey', key);
    }
  }

  /// Has the user (or the build) chosen a server? On first launch the welcome screen asks for one.
  static Future<bool> hasServer() async {
    if (_definedBaseUrl.isNotEmpty) return true;
    final saved = (await SharedPreferences.getInstance()).getString('baseUrl');
    return saved != null && saved.isNotEmpty;
  }

  /// Shown in the account's device list ("Pixel 7", "iPhone 15").
  static Future<String> deviceName() async {
    if (Platform.isAndroid) {
      final a = await DeviceInfoPlugin().androidInfo;
      return '${a.manufacturer} ${a.model}'.trim();
    }
    if (Platform.isIOS) {
      final i = await DeviceInfoPlugin().iosInfo;
      return i.utsname.machine.isNotEmpty
          ? '${i.name} (${i.utsname.machine})'
          : i.name;
    }
    return Platform.operatingSystem;
  }

  /// Last e-mail used to sign in on this phone (pre-fills the login form).
  static Future<String> lastEmail() async =>
      (await SharedPreferences.getInstance()).getString('lastEmail') ?? '';
  static Future<void> setLastEmail(String e) async =>
      (await SharedPreferences.getInstance()).setString('lastEmail', e.trim());

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

  /// Old v0.x anonymous device token (prefix agp_) rather than an account session (ags_).
  static Future<bool> isLegacyToken() async =>
      (await token())?.startsWith('agp_') ?? false;

  static Future<void> clearCredentials() async {
    await _secure.delete(key: 'userId');
    await _secure.delete(key: 'token');
  }
}
