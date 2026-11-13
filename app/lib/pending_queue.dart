import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'api.dart';

/// Scans that could not be uploaded (network/server down) are kept on disk and retried.
/// Each carries a client_scan_id, so a retry after a half-finished upload can never create a duplicate.
class PendingQueue {
  static Future<Directory> _dir() async {
    final d =
        Directory('${(await getApplicationSupportDirectory()).path}/pending');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<void> add(Map<String, dynamic> payload) async {
    final f = File('${(await _dir()).path}/${payload['client_scan_id']}.json');
    await f.writeAsString(jsonEncode(payload), flush: true);
  }

  static Future<int> count() async =>
      (await _dir()).listSync().where((e) => e.path.endsWith('.json')).length;

  /// Returns number uploaded. Permanently rejected payloads (422) are renamed aside, never silently deleted.
  static Future<int> flush() async {
    var ok = 0;
    for (final e in (await _dir())
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))) {
      try {
        final payload =
            Map<String, dynamic>.from(jsonDecode(await e.readAsString()));
        await Api.processScan(payload);
        await e.delete();
        ok++;
      } on ApiError catch (err) {
        if (err.retryable) break; // still offline: stop, keep the rest
        if (err.kind == ApiErrorKind.rejected)
          await e.rename('${e.path}.rejected');
        if (err.kind == ApiErrorKind.unauthorized) break;
      } catch (_) {
        await e.rename('${e.path}.corrupt');
      }
    }
    return ok;
  }
}
