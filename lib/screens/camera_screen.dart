import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../logic/models.dart';
import '../logic/rules.dart';
import '../platform/watchman_platform.dart';
import 'camera_clips_screen.dart';
import 'settings_screen.dart';

/// Camera mode: start or stop watching, see the PIN and address, a small preview and the status.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.platform});

  final WatchmanPlatform platform;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraState _state = const CameraState();
  CameraConfig _config = const CameraConfig();
  Map<String, bool> _perm = const {};
  Uint8List? _frame;
  StreamSubscription<Uint8List>? _previewSub;
  Timer? _poll;
  bool _busy = false;
  bool _dimmed = false;
  String? _error;

  WatchmanPlatform get _p => widget.platform;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _previewSub?.cancel();
    _p.setDim(false);
    _p.keepAwake(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final results = await Future.wait([_p.cameraState(), _p.getConfig(), _p.permissionStatus()]);
      if (!mounted) return;
      final st = results[0] as CameraState;
      setState(() {
        _state = st;
        _config = results[1] as CameraConfig;
        _perm = results[2] as Map<String, bool>;
      });
      _syncScreen();
    } catch (_) {}
  }

  /// Preview and dimming only make sense while watching with the screen on.
  void _syncScreen() {
    final watching = _state.running;
    final wantPreview = watching && !_dimmed;
    if (wantPreview && _previewSub == null) {
      _previewSub = _p.preview().listen((f) {
        if (mounted) setState(() => _frame = f);
      }, onError: (_) {});
    } else if (!wantPreview && _previewSub != null) {
      _previewSub!.cancel();
      _previewSub = null;
    }
    if (!watching && _frame != null) setState(() => _frame = null);
    _p.keepAwake(watching);
    if (!watching && _dimmed) _setDim(false);
  }

  void _setDim(bool on) {
    _dimmed = on;
    _p.setDim(on);
    _syncScreen();
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final names = ['camera', 'notifications', if (_config.audio) 'microphone'];
      final perm = await _p.requestPermissions(names);
      if (perm['camera'] != true) {
        setState(() => _error = 'Watchman needs the camera permission to watch.');
        return;
      }
      await _p.startCamera();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _refresh();
      if (_config.dim && mounted) _setDim(true);
    } catch (e) {
      setState(() => _error = 'Could not start: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    _setDim(false);
    await _p.stopCamera();
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await _refresh();
  }

  void _openSettings() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(platform: _p)));

  void _openClips() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CameraClipsScreen(platform: _p)));

  @override
  Widget build(BuildContext context) {
    if (_dimmed && _state.running) return _DimOverlay(state: _state, onWake: () => _setDim(false));
    return UiScaffold(
      appBar: UiAppBar(
        title: 'Camera',
        actions: [
          UiIconButton(Icons.video_library_rounded, tooltip: 'Clips', onPressed: _openClips),
          UiIconButton(Icons.settings_rounded, tooltip: 'Settings', onPressed: _openSettings),
        ],
      ),
      scrollable: true,
      body: UiColumn(
        gap: UiSpace.lg,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_state.running) ..._watching(context) else ..._idle(context),
        ],
      ),
    );
  }

  List<Widget> _idle(BuildContext context) {
    final camOk = _perm['camera'] == true;
    return [
      Text('This phone is the camera', style: context.text.titleLarge),
      Text(
        'Put it where you want to watch, plug it in, and start. Open Watchman in Viewer mode on your other phone '
        'on the same Wi-Fi and enter the PIN shown here.',
        style: context.text.bodyMedium?.copyWith(color: context.colors.textMuted),
      ),
      UiListGroup(
        header: 'What Watchman needs',
        children: [
          UiListTile(
            'Camera',
            subtitle: 'To see the room, detect motion and record clips.',
            icon: Icons.videocam_rounded,
            iconStatus: camOk ? UiStatus.success : UiStatus.warning,
            value: camOk ? 'Allowed' : 'Needed',
          ),
          UiListTile(
            'Notifications',
            subtitle: 'Android shows a notice while the camera keeps watching with the screen off.',
            icon: Icons.notifications_rounded,
            iconStatus: _perm['notifications'] == true ? UiStatus.success : UiStatus.neutral,
            value: _perm['notifications'] == true ? 'Allowed' : 'Asked on start',
          ),
          UiListTile(
            'Microphone (optional)',
            subtitle: _config.audio ? 'Clips will include sound.' : 'Off. Turn on in Settings to record sound.',
            icon: Icons.mic_rounded,
            iconStatus: UiStatus.neutral,
            value: _config.audio ? 'On' : 'Off',
          ),
        ],
      ),
      if (_error != null) UiAlert(_error!, status: UiStatus.danger),
      if (_state.error != null) UiAlert(_state.error!, status: UiStatus.warning),
      UiButton('Start watching', icon: Icons.play_arrow_rounded, loading: _busy, onPressed: _busy ? null : _start),
    ];
  }

  List<Widget> _watching(BuildContext context) {
    final s = _state;
    final last = s.lastMotionMs == 0 ? 'No motion yet' : 'Last motion ${Fmt.when(DateTime.fromMillisecondsSinceEpoch(s.lastMotionMs))}';
    return [
      UiCard(
        child: Column(
          children: [
            Text('PIN for the viewer', style: context.text.labelLarge?.copyWith(color: context.colors.textMuted)),
            const SizedBox(height: UiSpace.xs),
            Text(
              s.pin,
              style: context.text.displaySmall?.copyWith(letterSpacing: 8, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: UiSpace.sm),
            if (s.endpoint != null)
              UiKeyValue('Address', s.endpoint!, copyable: true, mono: true)
            else
              Text('No Wi-Fi address found. Connect to Wi-Fi.',
                  style: context.text.bodySmall?.copyWith(color: context.colors.warning)),
          ],
        ),
      ),
      ClipRRect(
        borderRadius: BorderRadius.circular(UiRadius.lg),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: ColoredBox(
            color: Colors.black,
            child: _frame == null
                ? const Center(child: UiSpinner())
                : Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.contain),
          ),
        ),
      ),
      Wrap(
        spacing: UiSpace.sm,
        runSpacing: UiSpace.sm,
        children: [
          UiStatusPill('Watching', status: UiStatus.success, pulse: true),
          UiStatusPill(s.motion ? 'Motion' : 'No motion', status: s.motion ? UiStatus.warning : UiStatus.neutral),
          if (s.recording) const UiStatusPill('Recording', status: UiStatus.danger, pulse: true),
          UiStatusPill('${s.viewers} watching now', status: s.viewers > 0 ? UiStatus.info : UiStatus.neutral),
        ],
      ),
      Text(last, style: context.text.bodySmall?.copyWith(color: context.colors.textMuted)),
      if (!s.recordingAvailable)
        const UiAlert('This phone cannot record video together with the live view. Motion is still detected and listed.',
            status: UiStatus.warning),
      if (s.error != null) UiAlert(s.error!, status: UiStatus.danger),
      UiButtonBar(
        [
          UiButton('Switch camera', variant: UiButtonVariant.outline, icon: Icons.cameraswitch_rounded, onPressed: () async {
            await _p.switchCamera();
            await Future<void>.delayed(const Duration(milliseconds: 500));
            _refresh();
          }),
          UiButton('Dim screen', variant: UiButtonVariant.outline, icon: Icons.brightness_low_rounded, onPressed: () => _setDim(true)),
        ],
        expand: true,
      ),
      UiButton('Stop watching', variant: UiButtonVariant.danger, icon: Icons.stop_rounded, onPressed: _stop),
    ];
  }
}

/// Black screen with the screen brightness at minimum. Tap anywhere to show the controls again.
class _DimOverlay extends StatelessWidget {
  const _DimOverlay({required this.state, required this.onWake});

  final CameraState state;
  final VoidCallback onWake;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onWake,
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_rounded, color: Colors.white24, size: 40),
                const SizedBox(height: UiSpace.sm),
                Text(
                  state.recording ? 'Recording' : 'Watching',
                  style: const TextStyle(color: Colors.white24),
                ),
                const SizedBox(height: UiSpace.xs),
                const Text('Tap to show controls', style: TextStyle(color: Colors.white24, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
