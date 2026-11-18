import 'package:flutter_test/flutter_test.dart';
import 'package:ppg_camera/ppg_camera.dart';

Map<String, dynamic> cam(String key, double fps, {bool flash = true, double video = 0, String kind = 'single'}) => {
      'key': key,
      'id': key,
      'label': 'Camera $key',
      'kind': kind,
      'hasFlash': flash,
      'manualSensor': true,
      'maxYuvFps': fps,
      'surfaceMaxFps': video,
      'meetsMinimum': flash && fps >= 54.5,
      'meetsTarget': flash && fps >= 59.5,
      'reason': !flash ? 'no flash/torch' : (fps >= 54.5 ? 'ok' : 'streams at most ${fps.round()} fps to apps (needs 55)'),
      'aeFpsRanges': [
        [10, 30]
      ],
      'highSpeedFpsRanges': <List<int>>[],
    };

void main() {
  test('lists logical and physical cameras with their own fps and reasons', () {
    final caps = PpgCapabilities.fromMap({
      'platform': 'android',
      'cameras': [cam('0', 30, kind: 'logical'), cam('0:2', 60, kind: 'physical'), cam('0:3', 30, flash: false, kind: 'physical')],
      'autoKey': '0:2',
      'meetsMinimum': true,
      'meetsTarget': true,
      'anyMeetsMinimum': true,
      'supports60': true,
      'hiddenPhysicalIds': ['0:4'],
      'chosen': {'key': '0:2', 'id': '0:2', 'label': 'Camera 0:2', 'w': 640, 'h': 480, 'maxFps': 60.0, 'manual': true},
    });
    expect(caps.cameras.length, 3);
    expect(caps.autoKey, '0:2');
    expect(caps.chosenCamera?.key, '0:2');
    expect(caps.chosenHasFlash, true);
    expect(caps.cameraByKey('0')!.usable, false);
    expect(caps.cameraByKey('0:3')!.reason, 'no flash/torch');
    expect(caps.hiddenPhysicalIds, ['0:4']);
    expect(caps.describe(), contains('hidden physical lenses: 0:4'));
  });

  test('no usable camera is reported honestly (the 30 fps-only phone)', () {
    final caps = PpgCapabilities.fromMap({
      'platform': 'android',
      'cameras': [cam('0', 30, video: 60)],
      'autoKey': null,
      'meetsMinimum': false,
      'meetsTarget': false,
      'anyMeetsMinimum': false,
      'supports60': false,
      'chosen': null,
    });
    expect(caps.meetsMinimum, false);
    expect(caps.anyMeetsMinimum, false);
    expect(caps.chosenCamera, isNull);
    expect(caps.cameras.single.surfaceMaxFps, 60);
    expect(caps.describe(), contains('NO usable camera'));
  });

  test('older native builds without the new keys still parse', () {
    final caps = PpgCapabilities.fromMap({
      'supports60': true,
      'cameras': [
        {'id': '0', 'hasFlash': true, 'manualSensor': true, 'maxYuvFps': 60.0, 'aeFpsRanges': []}
      ],
      'chosen': {'id': '0', 'w': 320, 'h': 240, 'maxFps': 60.0, 'manual': true},
    });
    expect(caps.meetsMinimum, true);
    expect(caps.platform, 'android');
    expect(caps.cameras.single.key, '0');
    expect(caps.chosenCamera?.key, '0');
  });
}
