import 'dart:convert';

/// Camera-mode settings, as stored by the Kotlin side.
class CameraConfig {
  const CameraConfig({
    this.facing = 'back',
    this.audio = false,
    this.dim = true,
    this.sensitivity = 60,
    this.minArea = 2,
    this.cooldownSec = 10,
    this.clipSec = 15,
    this.storageMb = 500,
    this.cameraName = 'Camera',
    this.pin = '',
    this.port = 8765,
  });

  final String facing;
  final bool audio;
  final bool dim;

  /// 1..100. Higher notices smaller brightness changes.
  final int sensitivity;

  /// Smallest share of the picture (percent) that counts as motion.
  final int minArea;
  final int cooldownSec;
  final int clipSec;

  /// Clip storage limit in MB. 0 = unlimited.
  final int storageMb;
  final String cameraName;
  final String pin;
  final int port;

  factory CameraConfig.fromMap(Map<Object?, Object?> m) => CameraConfig(
    facing: m['facing'] as String? ?? 'back',
    audio: m['audio'] as bool? ?? false,
    dim: m['dim'] as bool? ?? true,
    sensitivity: (m['sensitivity'] as num?)?.toInt() ?? 60,
    minArea: (m['minArea'] as num?)?.toInt() ?? 2,
    cooldownSec: (m['cooldownSec'] as num?)?.toInt() ?? 10,
    clipSec: (m['clipSec'] as num?)?.toInt() ?? 15,
    storageMb: (m['storageMb'] as num?)?.toInt() ?? 500,
    cameraName: m['cameraName'] as String? ?? 'Camera',
    pin: m['pin'] as String? ?? '',
    port: (m['port'] as num?)?.toInt() ?? 8765,
  );
}

/// Live state of the camera service.
class CameraState {
  const CameraState({
    this.running = false,
    this.recording = false,
    this.recordingAvailable = true,
    this.facing = 'back',
    this.lastMotionMs = 0,
    this.motion = false,
    this.viewers = 0,
    this.port = 0,
    this.addresses = const [],
    this.pin = '',
    this.name = '',
    this.error,
  });

  final bool running;
  final bool recording;
  final bool recordingAvailable;
  final String facing;
  final int lastMotionMs;
  final bool motion;
  final int viewers;
  final int port;
  final List<String> addresses;
  final String pin;
  final String name;
  final String? error;

  /// The first address with the port, e.g. `192.168.1.20:8765`, or null.
  String? get endpoint => addresses.isEmpty || port == 0 ? null : '${addresses.first}:$port';

  factory CameraState.fromMap(Map<Object?, Object?> m) => CameraState(
    running: m['running'] as bool? ?? false,
    recording: m['recording'] as bool? ?? false,
    recordingAvailable: m['recordingAvailable'] as bool? ?? true,
    facing: m['facing'] as String? ?? 'back',
    lastMotionMs: (m['lastMotionMs'] as num?)?.toInt() ?? 0,
    motion: m['motion'] as bool? ?? false,
    viewers: (m['viewers'] as num?)?.toInt() ?? 0,
    port: (m['port'] as num?)?.toInt() ?? 0,
    addresses: ((m['addresses'] as List?) ?? const []).cast<String>(),
    pin: m['pin'] as String? ?? '',
    name: m['name'] as String? ?? '',
    error: m['error'] as String?,
  );
}

/// One motion event reported by a camera.
class MotionEvent {
  const MotionEvent({required this.id, required this.time, required this.score, this.clip});

  final int id;
  final DateTime time;

  /// Changed share of the picture in percent.
  final double score;

  /// Clip file name on the camera phone, or null when none was recorded.
  final String? clip;

  factory MotionEvent.fromJson(Map<String, dynamic> j) => MotionEvent(
    id: (j['id'] as num).toInt(),
    time: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num).toInt()),
    score: (j['score'] as num?)?.toDouble() ?? 0,
    clip: j['clip'] as String?,
  );

  /// Parses a JSON array. Newest first.
  static List<MotionEvent> parseList(String json) {
    final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>().map(MotionEvent.fromJson).toList();
    list.sort((a, b) => b.id.compareTo(a.id));
    return list;
  }
}

class ClipInfo {
  const ClipInfo({required this.name, required this.size, required this.time});

  final String name;
  final int size;
  final DateTime time;

  factory ClipInfo.fromJson(Map<Object?, Object?> j) => ClipInfo(
    name: j['name'] as String,
    size: (j['size'] as num).toInt(),
    time: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num).toInt()),
  );

  static List<ClipInfo> parseList(String json) =>
      ((jsonDecode(json) as List).cast<Map<String, dynamic>>().map(ClipInfo.fromJson).toList())
        ..sort((a, b) => b.time.compareTo(a.time));
}

/// A camera found on the Wi-Fi (NSD).
class FoundCamera {
  const FoundCamera({required this.name, required this.host, required this.port});

  final String name;
  final String host;
  final int port;

  factory FoundCamera.fromMap(Map<Object?, Object?> m) =>
      FoundCamera(name: m['name'] as String? ?? 'Camera', host: m['host'] as String, port: (m['port'] as num).toInt());

  String get key => '$host:$port';
}

/// A camera the viewer remembers (with its PIN) and may monitor in the background.
class SavedCamera {
  const SavedCamera({
    required this.name,
    required this.host,
    required this.port,
    required this.pin,
    this.monitor = false,
  });

  final String name;
  final String host;
  final int port;
  final String pin;
  final bool monitor;

  String get key => '$host:$port';

  SavedCamera copyWith({String? name, String? pin, bool? monitor}) =>
      SavedCamera(name: name ?? this.name, host: host, port: port, pin: pin ?? this.pin, monitor: monitor ?? this.monitor);

  Map<String, Object?> toJson() => {'name': name, 'host': host, 'port': port, 'pin': pin, 'monitor': monitor};

  factory SavedCamera.fromJson(Map<String, dynamic> j) => SavedCamera(
    name: j['name'] as String? ?? 'Camera',
    host: j['host'] as String,
    port: (j['port'] as num?)?.toInt() ?? 8765,
    pin: j['pin'] as String? ?? '',
    monitor: j['monitor'] as bool? ?? false,
  );

  static String encodeList(List<SavedCamera> cams) => jsonEncode(cams.map((c) => c.toJson()).toList());

  static List<SavedCamera> decodeList(String json) {
    try {
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>().map(SavedCamera.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }
}
