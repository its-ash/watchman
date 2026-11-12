import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchman/logic/mjpeg_parser.dart';
import 'package:watchman/logic/models.dart';
import 'package:watchman/logic/rules.dart';

List<int> part(List<int> jpeg) => [
  ...ascii.encode('--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n'),
  ...jpeg,
  ...ascii.encode('\r\n'),
];

void main() {
  group('PinRules', () {
    test('accepts 4 to 6 digits', () {
      expect(PinRules.isValid('1234'), isTrue);
      expect(PinRules.isValid('12345'), isTrue);
      expect(PinRules.isValid('123456'), isTrue);
    });
    test('rejects short, long, non-digit and empty', () {
      expect(PinRules.isValid('123'), isFalse);
      expect(PinRules.isValid('1234567'), isFalse);
      expect(PinRules.isValid('12a4'), isFalse);
      expect(PinRules.isValid(''), isFalse);
      expect(PinRules.isValid(null), isFalse);
      expect(PinRules.validate('12'), isNotNull);
      expect(PinRules.validate('1234'), isNull);
    });
  });

  group('StorageLimits', () {
    test('labels', () {
      expect(StorageLimits.label(0), 'Unlimited');
      expect(StorageLimits.label(500), '500 MB');
      expect(StorageLimits.label(1000), '1 GB');
      expect(StorageLimits.label(2000), '2 GB');
    });
    test('nearest picks a listed option', () {
      expect(StorageLimits.nearest(0), 0);
      expect(StorageLimits.nearest(480), 500);
      expect(StorageLimits.nearest(5000), 2000);
      expect(StorageLimits.nearest(1), 100);
    });
  });

  group('Addresses.parse', () {
    test('host only uses the default port', () {
      final a = Addresses.parse('192.168.1.20')!;
      expect(a.host, '192.168.1.20');
      expect(a.port, 8765);
    });
    test('host and port, with scheme and path', () {
      final a = Addresses.parse(' http://192.168.1.20:9000/ ')!;
      expect(a.host, '192.168.1.20');
      expect(a.port, 9000);
    });
    test('rejects bad input', () {
      expect(Addresses.parse(''), isNull);
      expect(Addresses.parse('300.1.1.1'), isNull);
      expect(Addresses.parse('1.2.3.4:99999'), isNull);
      expect(Addresses.parse('1.2.3.4:abc'), isNull);
      expect(Addresses.parse('bad host'), isNull);
    });
  });

  group('Fmt', () {
    test('bytes', () {
      expect(Fmt.bytes(512), '512 B');
      expect(Fmt.bytes(2048), '2 KB');
      expect(Fmt.bytes(5 * 1024 * 1024), '5.0 MB');
    });
    test('when', () {
      final now = DateTime(2026, 11, 12, 18, 0);
      expect(Fmt.when(DateTime(2026, 11, 12, 9, 5), now: now), 'Today 09:05');
      expect(Fmt.when(DateTime(2026, 11, 3, 23, 59), now: now), '3 Nov 23:59');
    });
  });

  group('MjpegParser', () {
    test('parses frames split across arbitrary chunks', () {
      final a = List<int>.generate(300, (i) => i % 256);
      final b = List<int>.generate(50, (i) => 255 - i);
      final bytes = [...part(a), ...part(b)];
      final p = MjpegParser();
      final frames = <List<int>>[];
      for (var i = 0; i < bytes.length; i += 7) {
        frames.addAll(p.add(bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7)));
      }
      expect(frames.length, 2);
      expect(frames[0], a);
      expect(frames[1], b);
    });

    test('frame data may contain CRLF CRLF', () {
      final a = [1, 2, 13, 10, 13, 10, 3, 4];
      final p = MjpegParser();
      final frames = p.add(part(a));
      expect(frames.single, a);
    });

    test('returns nothing until a frame is complete', () {
      final bytes = part(List<int>.filled(100, 9));
      final p = MjpegParser();
      expect(p.add(bytes.sublist(0, bytes.length - 20)), isEmpty);
      expect(p.add(bytes.sublist(bytes.length - 20)).length, 1);
    });

    test('garbage without a header does not grow forever', () {
      final p = MjpegParser();
      expect(p.add(List<int>.filled(40000, 65)), isEmpty);
      expect(p.add(part([7, 8, 9])).length, 1);
    });
  });

  group('models', () {
    test('MotionEvent.parseList sorts newest first and reads the clip', () {
      final list = MotionEvent.parseList(
        '[{"id":1,"ts":1000,"score":3.5},{"id":2,"ts":2000,"score":12.0,"clip":"clip_1.mp4"}]',
      );
      expect(list.map((e) => e.id), [2, 1]);
      expect(list.first.clip, 'clip_1.mp4');
      expect(list.last.clip, isNull);
      expect(list.first.time, DateTime.fromMillisecondsSinceEpoch(2000));
    });

    test('SavedCamera round trips and survives bad json', () {
      final cams = [
        const SavedCamera(name: 'Hall', host: '192.168.1.5', port: 8765, pin: '1234', monitor: true),
        const SavedCamera(name: 'Door', host: '192.168.1.6', port: 9000, pin: '654321'),
      ];
      final back = SavedCamera.decodeList(SavedCamera.encodeList(cams));
      expect(back.length, 2);
      expect(back.first.monitor, isTrue);
      expect(back.last.key, '192.168.1.6:9000');
      expect(SavedCamera.decodeList('not json'), isEmpty);
    });

    test('CameraState.endpoint', () {
      expect(const CameraState().endpoint, isNull);
      final s = CameraState.fromMap({'addresses': ['10.0.0.4'], 'port': 8765, 'running': true});
      expect(s.endpoint, '10.0.0.4:8765');
      expect(s.running, isTrue);
    });

    test('CameraConfig defaults when keys are missing', () {
      final c = CameraConfig.fromMap(const {});
      expect(c.sensitivity, 60);
      expect(c.storageMb, 500);
      expect(c.facing, 'back');
    });
  });
}
