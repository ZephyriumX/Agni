import 'package:flutter/foundation.dart';

import 'api.dart';
import 'config.dart';

/// Signed-in state shared by the whole app. Screens listen to it; any 401 from the server signs the user out
/// here, which sends the app back to the sign-in screen with an explanation.
class Session extends ChangeNotifier {
  Session._() {
    Api.onUnauthorized = _expired;
  }
  static final Session instance = Session._();

  Map<String, dynamic>? user;
  bool signedIn = false;
  bool legacy =
      false; // old anonymous device profile that should be upgraded to an account
  String?
      notice; // message for the sign-in screen ("session expired", "signed out")

  String get displayName {
    final n = (user?['display_name'] as String?)?.trim();
    if (n != null && n.isNotEmpty) return n;
    final e = user?['email'] as String?;
    return e == null ? 'there' : e.split('@').first;
  }

  bool get onboarded => user?['onboarding_completed_at'] != null;
  String? get prakriti => user?['prakriti_type'] as String?;
  Map<String, dynamic> get profile => Map<String, dynamic>.from(
      (user?['profile'] ?? const <String, dynamic>{}) as Map);

  /// Restore from secure storage and refresh the profile. Throws ApiError if the server is unreachable while a
  /// token exists (the caller shows a retry screen; the token is kept).
  Future<void> restore() async {
    final t = await AppConfig.token();
    if (t == null) {
      signedIn = false;
      user = null;
      notifyListeners();
      return;
    }
    legacy = await AppConfig.isLegacyToken();
    user = await Api.me();
    signedIn = true;
    notifyListeners();
  }

  Future<void> signedInWith(AuthResult r) async {
    await AppConfig.saveCredentials(r.userId, r.token);
    if (r.user['email'] != null)
      await AppConfig.setLastEmail(r.user['email'] as String);
    user = r.user.isEmpty ? await Api.me() : r.user;
    signedIn = true;
    legacy = false;
    notice = null;
    notifyListeners();
  }

  Future<void> refresh() async {
    user = await Api.me();
    notifyListeners();
  }

  void setUser(Map<String, dynamic> u) {
    user = u;
    notifyListeners();
  }

  Future<void> signOut({bool everywhere = false, String? message}) async {
    if (everywhere) {
      try {
        await Api.logoutAll();
      } catch (_) {}
    } else {
      await Api.logout();
    }
    await _clear(message ?? 'You have been signed out.');
  }

  /// After account deletion: nothing to revoke on the server any more.
  Future<void> forget(String message) => _clear(message);

  Future<void> _clear(String message) async {
    await AppConfig.clearCredentials();
    user = null;
    signedIn = false;
    legacy = false;
    notice = message;
    notifyListeners();
  }

  void _expired() {
    if (!signedIn) return;
    _clear(
        'Your session ended (signed out on another device or expired). Please sign in again.');
  }
}
