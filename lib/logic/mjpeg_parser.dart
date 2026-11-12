import 'dart:typed_data';

/// Splits a `multipart/x-mixed-replace` body into JPEG frames. Feed chunks with [add]; each call
/// returns the frames completed by that chunk. Parts must carry `Content-Length` (the Watchman camera
/// always does).
class MjpegParser {
  final List<int> _buf = [];
  static const int _maxFrame = 8 * 1024 * 1024;

  List<Uint8List> add(List<int> chunk) {
    _buf.addAll(chunk);
    final frames = <Uint8List>[];
    while (true) {
      final headerEnd = _find(const [13, 10, 13, 10], 0);
      if (headerEnd < 0) {
        if (_buf.length > 16 * 1024) _buf.clear(); // garbage, no header in sight
        break;
      }
      final header = String.fromCharCodes(_buf.sublist(0, headerEnd));
      final m = RegExp(r'content-length:\s*(\d+)', caseSensitive: false).firstMatch(header);
      if (m == null) {
        // A boundary without a length: skip this header and look for the next one.
        _buf.removeRange(0, headerEnd + 4);
        continue;
      }
      final length = int.parse(m.group(1)!);
      if (length <= 0 || length > _maxFrame) {
        _buf.clear();
        break;
      }
      final start = headerEnd + 4;
      if (_buf.length < start + length) break; // wait for more bytes
      frames.add(Uint8List.fromList(_buf.sublist(start, start + length)));
      _buf.removeRange(0, start + length);
    }
    return frames;
  }

  int _find(List<int> pattern, int from) {
    for (var i = from; i <= _buf.length - pattern.length; i++) {
      var ok = true;
      for (var j = 0; j < pattern.length; j++) {
        if (_buf[i + j] != pattern[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }
}
