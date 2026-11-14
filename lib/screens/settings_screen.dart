import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../logic/models.dart';
import '../logic/rules.dart';
import '../platform/watchman_platform.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.platform});

  final WatchmanPlatform platform;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  CameraConfig? _c;
  Map<String, bool> _perm = const {};

  /// Slider values while dragging, so the thumb moves before the value is saved.
  final Map<String, double> _drag = {};

  WatchmanPlatform get _p => widget.platform;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await _p.getConfig();
    final perm = await _p.permissionStatus();
    if (!mounted) return;
    setState(() {
      _c = c;
      _perm = perm;
      _drag.clear();
    });
  }

  Future<void> _set(String key, Object value) async {
    await _p.setConfig(key, value);
    if (key == 'storageMb') await _p.enforceLimit();
    await _load();
  }

  Widget _slider(String key, String label, int value, double min, double max, String Function(double) format) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UiSpace.lg, vertical: UiSpace.sm),
      child: UiSlider(
        label: label,
        value: (_drag[key] ?? value.toDouble()).clamp(min, max),
        min: min,
        max: max,
        divisions: (max - min).round(),
        format: format,
        onChanged: (v) => setState(() => _drag[key] = v),
        onChangeEnd: (v) => _set(key, v.round()),
      ),
    );
  }

  Future<void> _editName(CameraConfig c) async {
    final v = await UiDialog.prompt(
      context,
      title: 'Camera name',
      message: 'Shown to the viewer.',
      initialValue: c.cameraName,
      validator: (s) => s.trim().isEmpty ? 'Enter a name.' : null,
    );
    if (v != null) _set('cameraName', v.trim());
  }

  Future<void> _editPin() async {
    final v = await UiDialog.prompt(
      context,
      title: 'Set a PIN',
      message: 'Viewers need this PIN. Use 4 to 6 digits.',
      label: 'PIN',
      keyboardType: TextInputType.number,
      validator: PinRules.validate,
    );
    if (v != null) _set('pin', v);
  }

  Future<void> _newPin() async {
    await _p.regeneratePin();
    await _load();
    if (mounted) context.showToast('New PIN created. Viewers must enter it again.', status: UiStatus.info);
  }

  Future<void> _pickStorage(CameraConfig c) async {
    final v = await UiDialog.show<int>(
      context,
      title: 'Storage limit',
      message: 'When the clips are bigger than this, the oldest are deleted first.',
      actions: [
        for (final mb in StorageLimits.options)
          UiDialogAction(StorageLimits.label(mb), value: mb, primary: mb == StorageLimits.nearest(c.storageMb)),
      ],
    );
    if (v != null) _set('storageMb', v);
  }

  Future<void> _setAudio(bool on) async {
    if (on) {
      final perm = await _p.requestPermissions(['microphone']);
      if (perm['microphone'] != true) {
        if (mounted) context.showToast('Microphone permission was not given.', status: UiStatus.warning);
        await _load();
        return;
      }
    }
    await _set('audio', on);
  }

  Widget _permTile(String title, String why, IconData icon, String key, {bool optional = false}) {
    final ok = _perm[key] == true;
    return UiListTile(
      title,
      subtitle: why,
      icon: icon,
      iconStatus: ok ? UiStatus.success : UiStatus.neutral,
      value: ok ? 'Allowed' : (optional ? 'Optional' : 'Not yet'),
      maxSubtitleLines: 4,
      onTap: ok
          ? null
          : () async {
              await _p.requestPermissions([key]);
              _load();
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return UiScaffold(
      appBar: const UiAppBar(title: 'Settings'),
      scrollable: true,
      body: c == null
          ? const Center(child: UiSpinner())
          : UiColumn(
              gap: UiSpace.lg,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UiListGroup(
                  header: 'Camera',
                  footer: 'Applies when this phone is the camera.',
                  children: [
                    UiListTile('Camera name', subtitle: 'Shown to the viewer', icon: Icons.badge_rounded, value: c.cameraName, chevron: true, onTap: () => _editName(c)),
                    UiListTile('PIN', subtitle: 'Tap to set your own', icon: Icons.password_rounded, value: c.pin, chevron: true, onTap: _editPin),
                    UiListTile('New random PIN', icon: Icons.refresh_rounded, chevron: true, onTap: _newPin),
                    UiSwitchTile(
                      'Dim screen while watching',
                      subtitle: 'Black screen at the lowest brightness. Tap it to show the controls.',
                      icon: Icons.brightness_low_rounded,
                      value: c.dim,
                      onChanged: (v) => _set('dim', v),
                    ),
                    UiSwitchTile(
                      'Record sound',
                      subtitle: 'Add the microphone to clips. Needs the microphone permission.',
                      icon: Icons.mic_rounded,
                      value: c.audio,
                      onChanged: _setAudio,
                    ),
                  ],
                ),
                UiSection(
                  title: 'Camera to use',
                  child: UiSegmentedControl<String>(
                    const [UiSegment('back', label: 'Back'), UiSegment('front', label: 'Front')],
                    value: c.facing,
                    expand: true,
                    onChanged: (v) => _set('facing', v),
                  ),
                ),
                UiListGroup(
                  header: 'Motion detection',
                  footer: 'Watchman compares small grayscale copies of the picture four times a second. '
                      'Raise the sensitivity to notice fainter changes. Raise "ignore small changes" if shadows or '
                      'sensor noise trigger clips.',
                  children: [
                    UiSwitchTile(
                      'Auto record',
                      subtitle: 'Record a clip when motion is seen. Off: motion is only listed, and clips are '
                          'recorded only when you press Record in the viewer or the browser.',
                      icon: Icons.fiber_manual_record_rounded,
                      value: c.autoRecord,
                      onChanged: (v) => _set('autoRecord', v),
                    ),
                    _slider('sensitivity', 'Sensitivity', c.sensitivity, 1, 100, (v) => '${v.round()}'),
                    _slider('minArea', 'Ignore changes smaller than', c.minArea, 1, 30, (v) => '${v.round()}% of the picture'),
                    _slider('cooldownSec', 'Wait between clips', c.cooldownSec, 0, 120, (v) => '${v.round()} s'),
                    _slider('clipSec', 'Clip length', c.clipSec, 5, 60, (v) => '${v.round()} s'),
                  ],
                ),
                UiListGroup(
                  header: 'Storage',
                  children: [
                    UiListTile(
                      'Storage limit',
                      subtitle: 'The oldest clips are deleted first.',
                      icon: Icons.sd_storage_rounded,
                      value: StorageLimits.label(c.storageMb),
                      chevron: true,
                      onTap: () => _pickStorage(c),
                    ),
                  ],
                ),
                UiListGroup(
                  header: 'Permissions',
                  footer: 'Watchman has no cloud and no account. The network permissions are only for talking to the '
                      'other phone on your Wi-Fi, and for the update check below.',
                  children: [
                    _permTile('Camera', 'See the room, detect motion and record clips.', Icons.videocam_rounded, 'camera'),
                    _permTile('Microphone', 'Record sound in clips, only if you turn "Record sound" on.', Icons.mic_rounded, 'microphone', optional: true),
                    _permTile('Notifications', 'Show that the camera is watching, and alert you in Viewer mode when motion is seen.', Icons.notifications_rounded, 'notifications'),
                    const UiListTile(
                      'Network and Wi-Fi',
                      subtitle: 'Serve the live view on your Wi-Fi, find cameras (multicast) and read the Wi-Fi address.',
                      icon: Icons.wifi_rounded,
                      value: 'Automatic',
                      maxSubtitleLines: 4,
                    ),
                    const UiListTile(
                      'Run in the background',
                      subtitle: 'Keep watching with the screen off. A wake lock is held only while the camera or the Monitor is running.',
                      icon: Icons.bolt_rounded,
                      value: 'Automatic',
                      maxSubtitleLines: 4,
                    ),
                  ],
                ),
                const UiAppearanceSection(),
                const UiUpdateSection(storeId: 'watchman'),
                const UiDeveloperSection(),
              ],
            ),
    );
  }
}
