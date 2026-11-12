import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchman/logic/camera_client.dart';

/// Runs the client against a small local server that behaves like the camera.
void main() {
  late HttpServer server;
  final frames = [
    List<int>.generate(120, (i) => i),
    List<int>.generate(80, (i) => 200 - i),
  ];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/hello') {
        res.write(jsonEncode({'app': 'watchman', 'name': 'Test cam'}));
        await res.close();
        return;
      }
      final pin = req.headers.value('x-pin') ?? req.uri.queryParameters['pin'];
      if (pin != '1234') {
        res.statusCode = 401;
        await res.close();
        return;
      }
      switch (req.uri.path) {
        case '/status':
          res.write(jsonEncode({'app': 'watchman', 'name': 'Test cam'}));
        case '/events':
          res.write(jsonEncode([
            {'id': 1, 'ts': 1000, 'score': 4.0},
            {'id': 2, 'ts': 2000, 'score': 9.5, 'clip': 'clip_a.mp4'},
          ]));
        case '/clips':
          res.write(jsonEncode([
            {'name': 'clip_a.mp4', 'size': 10, 'ts': 2000},
          ]));
        case '/clips/clip_a.mp4':
          res.headers.contentType = ContentType('video', 'mp4');
          res.contentLength = 10; // the real camera sends Content-Length too
          res.add(List<int>.filled(10, 7));
        case '/stream':
          res.headers.set('Content-Type', 'multipart/x-mixed-replace; boundary=frame');
          for (final f in frames) {
            res.add(ascii.encode('--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${f.length}\r\n\r\n'));
            res.add(f);
            res.add(ascii.encode('\r\n'));
            await res.flush();
          }
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  });

  tearDown(() => server.close(force: true));

  CameraClient client(String pin) => CameraClient(host: '127.0.0.1', port: server.port, pin: pin);

  test('hello needs no PIN', () async {
    expect(await client('').hello(), 'Test cam');
  });

  test('wrong PIN throws PinRejected', () async {
    await expectLater(client('0000').status(), throwsA(isA<PinRejected>()));
  });

  test('status, events and clips with the right PIN', () async {
    final c = client('1234');
    expect((await c.status())['name'], 'Test cam');
    final events = await c.events();
    expect(events.map((e) => e.id), [2, 1]);
    expect(events.first.clip, 'clip_a.mp4');
    expect((await c.clips()).single.name, 'clip_a.mp4');
  });

  test('stream yields every frame', () async {
    final got = await client('1234').stream().toList();
    expect(got.length, 2);
    expect(got[0], frames[0]);
    expect(got[1], frames[1]);
  });

  test('stream reports a rejected PIN as an error', () async {
    await expectLater(client('0000').stream().toList(), throwsA(isA<PinRejected>()));
  });

  test('clipUrl carries the PIN in the query', () {
    expect(client('1234').clipUrl('clip_a.mp4'), contains('pin=1234'));
    expect(client('1234').clipUrl('clip_a.mp4'), contains('/clips/clip_a.mp4'));
  });

  test('download writes the file and reports progress', () async {
    final dir = await Directory.systemTemp.createTemp('watchman_test');
    addTearDown(() => dir.delete(recursive: true));
    final seen = <double>[];
    final f = await client('1234').download('clip_a.mp4', dir.path, onProgress: seen.add);
    expect(await f.readAsBytes(), List<int>.filled(10, 7));
    expect(seen, isNotEmpty);
    expect(seen.last, 1.0);
  });

  test('download keeps a hostile name inside the folder', () async {
    final dir = await Directory.systemTemp.createTemp('watchman_test');
    addTearDown(() => dir.delete(recursive: true));
    // The server answers 404 for this name; the point is that nothing is written outside [dir].
    await expectLater(client('1234').download('../evil.mp4', dir.path), throwsA(isA<Exception>()));
    expect(File('${dir.parent.path}/evil.mp4').existsSync(), isFalse);
  });
}
