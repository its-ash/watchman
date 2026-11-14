import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'mjpeg_parser.dart';
import 'models.dart';

/// The camera did not accept the PIN.
class PinRejected implements Exception {
  const PinRejected({this.locked = false});

  /// Too many wrong tries: the camera blocks this phone for a minute.
  final bool locked;

  @override
  String toString() => locked ? 'Too many wrong PINs. Try again in a minute.' : 'Wrong PIN.';
}

/// The camera refused a control (e.g. "Already recording."). [message] is meant for the user.
class ControlFailed implements Exception {
  const ControlFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// HTTP client for one Watchman camera on the local network.
class CameraClient {
  CameraClient({required this.host, required this.port, required this.pin});

  final String host;
  final int port;
  final String pin;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: host, port: port, path: path, queryParameters: query);

  /// URL for the video player, which cannot send headers. The PIN travels in the query.
  String clipUrl(String name) => _uri('/clips/$name', {'pin': pin}).toString();

  HttpClient _http() => HttpClient()..connectionTimeout = const Duration(seconds: 5);

  Future<HttpClientResponse> _get(HttpClient c, String path, [Map<String, String>? query, bool auth = true]) async {
    final req = await c.getUrl(_uri(path, query));
    if (auth) req.headers.set('X-Pin', pin);
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode == 401 || res.statusCode == 429) {
      await res.drain<void>();
      throw PinRejected(locked: res.statusCode == 429);
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('Camera answered ${res.statusCode}', uri: _uri(path));
    }
    return res;
  }

  Future<String> _text(String path, [Map<String, String>? query, bool auth = true]) async {
    final c = _http();
    try {
      final res = await _get(c, path, query, auth);
      return await utf8.decodeStream(res).timeout(const Duration(seconds: 8));
    } finally {
      c.close(force: true);
    }
  }

  /// Camera name from the open `/hello` route (no PIN needed).
  Future<String> hello() async {
    final j = jsonDecode(await _text('/hello', null, false)) as Map<String, dynamic>;
    if (j['app'] != 'watchman') throw const FormatException('Not a Watchman camera');
    return j['name'] as String? ?? 'Camera';
  }

  /// Throws [PinRejected] when the PIN is wrong.
  Future<Map<String, dynamic>> status() async => jsonDecode(await _text('/status')) as Map<String, dynamic>;

  Future<RemoteStatus> remoteStatus() async => RemoteStatus.fromJson(await status());

  /// POSTs a control. Returns the camera's status right after it; throws [ControlFailed] with the camera's
  /// reason when it refuses, [PinRejected] on a wrong PIN.
  Future<RemoteStatus> _control(String path, [Map<String, Object?> body = const {}]) async {
    final c = _http();
    try {
      final req = await c.postUrl(_uri(path));
      req.headers.set('X-Pin', pin);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await utf8.decodeStream(res).timeout(const Duration(seconds: 8));
      if (res.statusCode == 401 || res.statusCode == 429) throw PinRejected(locked: res.statusCode == 429);
      Map<String, dynamic>? j;
      try {
        j = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      if (res.statusCode != 200) {
        // A camera on Watchman 1.0.1 or older has no controls: it answers every POST with {"error":"bad request"}.
        final error = j?['error'] as String?;
        if (error == null || error == 'bad request') {
          throw const ControlFailed('Update Watchman on the camera phone to use this.');
        }
        throw ControlFailed(error);
      }
      final s = j?['status'];
      return s is Map<String, dynamic> ? RemoteStatus.fromJson(s) : await remoteStatus();
    } finally {
      c.close(force: true);
    }
  }

  Future<RemoteStatus> switchCamera() => _control('/control/switch');

  Future<RemoteStatus> setTorch(bool on) => _control('/control/torch', {'on': on});

  /// Records one clip of the camera's clip length now.
  Future<RemoteStatus> recordNow() => _control('/control/record');

  /// Motion settings: any of `sensitivity`, `minArea`, `cooldownSec`, `clipSec`.
  Future<RemoteStatus> updateSettings(Map<String, int> values) => _control('/control/settings', values);

  /// Turns recording on motion on or off.
  Future<RemoteStatus> setAutoRecord(bool on) => _control('/control/settings', {'autoRecord': on});

  Future<void> deleteClip(String name) => _control('/control/delete-clip', {'name': name});

  Future<List<MotionEvent>> events({int since = 0}) async =>
      MotionEvent.parseList(await _text('/events', {'since': '$since'}));

  Future<List<ClipInfo>> clips() async => ClipInfo.parseList(await _text('/clips'));

  /// Live frames as JPEG bytes. Ends when the connection closes; errors surface on the stream.
  Stream<Uint8List> stream() {
    late StreamController<Uint8List> controller;
    HttpClient? client;
    StreamSubscription<List<int>>? sub;
    controller = StreamController<Uint8List>(
      onListen: () async {
        client = _http();
        try {
          final res = await _get(client!, '/stream');
          final parser = MjpegParser();
          sub = res.listen(
            (chunk) {
              for (final f in parser.add(chunk)) {
                if (!controller.isClosed) controller.add(f);
              }
            },
            onError: (Object e) {
              if (!controller.isClosed) controller.addError(e);
            },
            onDone: () {
              if (!controller.isClosed) controller.close();
            },
            cancelOnError: true,
          );
        } catch (e) {
          if (!controller.isClosed) {
            controller.addError(e);
            await controller.close();
          }
        }
      },
      onCancel: () async {
        await sub?.cancel();
        client?.close(force: true);
      },
    );
    return controller.stream;
  }

  /// Downloads a clip to [dir] and returns the file. [onProgress] gets 0..1 when the size is known.
  Future<File> download(String name, String dir, {void Function(double)? onProgress}) async {
    final c = _http();
    try {
      final res = await _get(c, '/clips/$name');
      // The name comes from the network: keep only safe characters so it cannot leave [dir].
      final file = File('$dir/${name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}');
      final sink = file.openWrite();
      var got = 0;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (res.contentLength > 0) onProgress?.call(got / res.contentLength);
        }
      } finally {
        await sink.close();
      }
      return file;
    } finally {
      c.close(force: true);
    }
  }
}
