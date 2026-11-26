import 'dart:async';

import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../logic/camera_client.dart';
import '../logic/models.dart';
import '../logic/rules.dart';
import '../platform/watchman_platform.dart';
import 'live_screen.dart';

/// Viewer mode: cameras found on the Wi-Fi, saved cameras, manual address entry and the Monitor switch.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.platform});

  final WatchmanPlatform platform;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  List<SavedCamera> _saved = const [];
  List<FoundCamera> _found = const [];
  StreamSubscription<List<FoundCamera>>? _sub;
  bool _loaded = false;
  bool _busy = false;

  WatchmanPlatform get _p => widget.platform;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = _p.discover().listen((list) {
      if (mounted) setState(() => _found = list);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final saved = await _p.savedCameras();
    if (!mounted) return;
    setState(() {
      _saved = saved;
      _loaded = true;
    });
  }

  Future<void> _store(List<SavedCamera> list) async {
    if (!mounted) return;
    setState(() => _saved = list);
    await _p.saveCameras(list);
  }

  /// Asks for the PIN and checks it against the camera. Returns the saved camera, or null if cancelled.
  Future<SavedCamera?> _pair(String name, String host, int port) async {
    final pin = await UiDialog.prompt(
      context,
      title: 'PIN for $name',
      message: 'Enter the PIN shown on the camera phone.',
      label: 'PIN',
      hint: '123456',
      keyboardType: TextInputType.number,
      validator: PinRules.validate,
      confirmLabel: 'Connect',
    );
    if (pin == null || !mounted) return null;
    setState(() => _busy = true);
    try {
      await CameraClient(host: host, port: port, pin: pin).status();
      if (!mounted) return null;
      final cam = SavedCamera(name: name, host: host, port: port, pin: pin);
      final list = [..._saved.where((c) => c.key != cam.key), cam];
      await _store(list);
      return cam;
    } on PinRejected catch (e) {
      if (mounted) context.showToast(e.toString(), status: UiStatus.danger);
      return null;
    } catch (_) {
      if (mounted) context.showToast('Could not reach the camera. Check it is watching and on the same Wi-Fi.', status: UiStatus.danger);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(SavedCamera cam) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LiveScreen(platform: _p, camera: cam)));
  }

  Future<void> _openFound(FoundCamera f) async {
    final existing = _saved.where((c) => c.key == f.key).firstOrNull;
    if (existing != null) return _open(existing);
    final cam = await _pair(f.name, f.host, f.port);
    if (!mounted || cam == null) return;
    _open(cam);
  }

  Future<void> _addManual() async {
    final text = await UiDialog.prompt(
      context,
      title: 'Add a camera',
      message: 'Enter the address shown on the camera phone, for example 192.168.1.20:8765.',
      label: 'Address',
      hint: '192.168.1.20:8765',
      keyboardType: TextInputType.url,
      validator: (v) => Addresses.parse(v) == null ? 'Enter an IP address like 192.168.1.20:8765.' : null,
      confirmLabel: 'Next',
    );
    if (text == null || !mounted) return;
    final addr = Addresses.parse(text)!;
    setState(() => _busy = true);
    String name;
    try {
      name = await CameraClient(host: addr.host, port: addr.port, pin: '').hello();
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        context.showToast('No Watchman camera found at that address.', status: UiStatus.danger);
      }
      return;
    }
    if (mounted) setState(() => _busy = false);
    if (!mounted) return;
    final cam = await _pair(name, addr.host, addr.port);
    if (!mounted || cam == null) return;
    _open(cam);
  }

  Future<void> _remove(SavedCamera cam) async {
    final ok = await UiDialog.confirm(
      context,
      title: 'Forget ${cam.name}?',
      message: 'The saved PIN is removed. You can add the camera again later.',
      destructive: true,
      confirmLabel: 'Forget',
    );
    if (!mounted || !ok) return;
    await _store(_saved.where((c) => c.key != cam.key).toList());
  }

  Future<void> _setMonitor(SavedCamera cam, bool on) async {
    if (on) {
      // Android 13+ needs the notification permission to show motion alerts.
      final perm = await _p.requestPermissions(['notifications']);
      if (perm['notifications'] != true) {
        if (mounted) context.showToast('Allow notifications to get motion alerts.', status: UiStatus.warning);
        return;
      }
    }
    if (!mounted) return;
    await _store(_saved.map((c) => c.key == cam.key ? c.copyWith(monitor: on) : c).toList());
  }

  @override
  Widget build(BuildContext context) {
    final savedKeys = _saved.map((c) => c.key).toSet();
    final newFound = _found.where((f) => !savedKeys.contains(f.key)).toList();
    return UiScaffold(
      appBar: const UiAppBar(title: 'Viewer'),
      scrollable: true,
      body: !_loaded
          ? const Center(child: UiSpinner())
          : UiColumn(
              gap: UiSpace.lg,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Pick a camera on this Wi-Fi. The camera phone shows the PIN once it is watching.',
                  style: context.text.bodyMedium?.copyWith(color: context.colors.textMuted),
                ),
                if (_saved.isNotEmpty)
                  UiListGroup(
                    header: 'Your cameras',
                    children: [
                      for (final c in _saved)
                        UiListTile(
                          c.name,
                          subtitle: c.key,
                          icon: Icons.videocam_rounded,
                          chevron: true,
                          onTap: () => _open(c),
                          onLongPress: () => _remove(c),
                        ),
                    ],
                  ),
                UiListGroup(
                  header: 'Found on Wi-Fi',
                  footer: 'Cameras appear here by themselves. If yours does not, add it by address.',
                  children: [
                    if (newFound.isEmpty)
                      const UiListTile('Searching...', subtitle: 'No new camera found yet.', icon: Icons.wifi_find_rounded),
                    for (final f in newFound)
                      UiListTile(f.name, subtitle: f.key, icon: Icons.videocam_outlined, chevron: true, onTap: () => _openFound(f)),
                  ],
                ),
                UiButton('Add by address', variant: UiButtonVariant.outline, icon: Icons.add_rounded, loading: _busy, onPressed: _busy ? null : _addManual),
                if (_saved.isNotEmpty)
                  UiListGroup(
                    header: 'Motion alerts',
                    footer: 'Monitor checks the camera every few seconds and notifies you when it sees motion, even when '
                        'Watchman is closed. While on, Android shows a notice and the phone stays awake for the check.',
                    children: [
                      for (final c in _saved)
                        UiSwitchTile(
                          'Monitor ${c.name}',
                          subtitle: c.monitor ? 'On' : 'Off',
                          icon: Icons.notifications_active_rounded,
                          value: c.monitor,
                          onChanged: (v) => _setMonitor(c, v),
                        ),
                    ],
                  ),
                if (_saved.isNotEmpty)
                  Text('Long-press a camera to forget it.', style: context.text.bodySmall?.copyWith(color: context.colors.textSubtle)),
              ],
            ),
    );
  }
}
