import 'dart:async';
import 'package:flutter/services.dart';

import '../logic/models.dart';

/// Everything native: the camera service, permissions, clip files, discovery. Screens only use this
/// interface, so tests can pass a fake.
abstract class WatchmanPlatform {
  Future<CameraConfig> getConfig();
  Future<void> setConfig(String key, Object value);

  /// Keys: `camera`, `microphone`, `notifications`.
  Future<Map<String, bool>> permissionStatus();
  Future<Map<String, bool>> requestPermissions(List<String> names);

  Future<void> startCamera();
  Future<void> stopCamera();
  Future<void> switchCamera();
  Future<CameraState> cameraState();
  Future<String> regeneratePin();

  Future<List<ClipInfo>> listClips();
  Future<void> deleteClip(String name);
  Future<void> deleteAllClips();
  Future<List<MotionEvent>> localEvents();
  Future<void> clearEvents();
  Future<void> enforceLimit();

  /// JPEG frames of the camera while this phone watches. Only produced while listened to.
  Stream<Uint8List> preview();

  /// Cameras found on the Wi-Fi. Discovery runs while listened to.
  Stream<List<FoundCamera>> discover();

  Future<List<SavedCamera>> savedCameras();

  /// Saves the list. Starts or stops the background monitor to match the `monitor` flags.
  Future<void> saveCameras(List<SavedCamera> cameras);

  Future<String> downloadDir();
  Future<void> setDim(bool on);
  Future<void> keepAwake(bool on);
}

class MethodChannelWatchmanPlatform implements WatchmanPlatform {
  static const _control = MethodChannel('com.itsash.watchman/control');
  static const _preview = EventChannel('com.itsash.watchman/preview');
  static const _discovery = EventChannel('com.itsash.watchman/discovery');

  Future<T?> _call<T>(String m, [Map<String, Object?>? args]) => _control.invokeMethod<T>(m, args);

  @override
  Future<CameraConfig> getConfig() async => CameraConfig.fromMap((await _call<Map>('getConfig'))!);

  @override
  Future<void> setConfig(String key, Object value) => _call('setConfig', {'key': key, 'value': value});

  Map<String, bool> _perm(Map? m) => {for (final e in (m ?? const {}).entries) e.key as String: e.value == true};

  @override
  Future<Map<String, bool>> permissionStatus() async => _perm(await _call<Map>('permissionStatus'));

  @override
  Future<Map<String, bool>> requestPermissions(List<String> names) async =>
      _perm(await _call<Map>('requestPermissions', {'names': names}));

  @override
  Future<void> startCamera() => _call('startCamera');

  @override
  Future<void> stopCamera() => _call('stopCamera');

  @override
  Future<void> switchCamera() => _call('switchCamera');

  @override
  Future<CameraState> cameraState() async => CameraState.fromMap((await _call<Map>('cameraState'))!);

  @override
  Future<String> regeneratePin() async => (await _call<String>('regeneratePin'))!;

  @override
  Future<List<ClipInfo>> listClips() async =>
      ((await _call<List>('listClips')) ?? const []).map((e) => ClipInfo.fromJson(e as Map)).toList();

  @override
  Future<void> deleteClip(String name) => _call('deleteClip', {'name': name});

  @override
  Future<void> deleteAllClips() => _call('deleteAllClips');

  @override
  Future<List<MotionEvent>> localEvents() async => MotionEvent.parseList((await _call<String>('localEvents')) ?? '[]');

  @override
  Future<void> clearEvents() => _call('clearEvents');

  @override
  Future<void> enforceLimit() => _call('enforceLimit');

  @override
  Stream<Uint8List> preview() => _preview.receiveBroadcastStream().map((e) => e as Uint8List);

  @override
  Stream<List<FoundCamera>> discover() => _discovery.receiveBroadcastStream().map(
    (e) => (e as List).map((m) => FoundCamera.fromMap(m as Map)).toList(),
  );

  @override
  Future<List<SavedCamera>> savedCameras() async => SavedCamera.decodeList((await _call<String>('savedCameras')) ?? '[]');

  @override
  Future<void> saveCameras(List<SavedCamera> cameras) => _call('saveCameras', {'json': SavedCamera.encodeList(cameras)});

  @override
  Future<String> downloadDir() async => (await _call<String>('downloadDir'))!;

  @override
  Future<void> setDim(bool on) => _call('setDim', {'on': on});

  @override
  Future<void> keepAwake(bool on) => _call('keepAwake', {'on': on});
}
