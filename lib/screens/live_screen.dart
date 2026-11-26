import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:theme/theme.dart';

import '../logic/camera_client.dart';
import '../logic/models.dart';
import '../platform/watchman_platform.dart';
import 'events_screen.dart';

/// Full-screen live view (MJPEG) of one camera with remote controls (switch camera, light, record a clip,
/// motion settings). The same controls are on the camera's web page. Reconnects when the connection drops.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key, required this.platform, required this.camera});

  final WatchmanPlatform platform;
  final SavedCamera camera;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  late final CameraClient _client = CameraClient(host: widget.camera.host, port: widget.camera.port, pin: widget.camera.pin);
  StreamSubscription<Uint8List>? _sub;
  Timer? _retry;
  Timer? _poll;
  Timer? _afterControl;
  Uint8List? _frame;
  String? _problem;
  bool _fatal = false;
  bool _chrome = true;
  RemoteStatus? _status;

  /// The control being sent, so its button shows a spinner.
  String? _busy;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    widget.platform.keepAwake(true);
    _connect();
    _refreshStatus();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refreshStatus());
  }

  Future<void> _refreshStatus() async {
    try {
      final s = await _client.remoteStatus();
      if (mounted) setState(() => _status = s);
    } catch (_) {
      // The stream shows connection problems; the controls just keep their last state.
    }
  }

  Future<void> _send(String id, Future<RemoteStatus> Function() action, {String? done}) async {
    if (_busy != null) return;
    setState(() => _busy = id);
    try {
      final s = await action();
      if (!mounted) return;
      setState(() => _status = s);
      if (done != null) context.showToast(done, status: UiStatus.success);
      _afterControl?.cancel();
      _afterControl = Timer(const Duration(milliseconds: 800), _refreshStatus);
    } catch (e) {
      if (mounted) {
        context.showToast(e is ControlFailed || e is PinRejected ? e.toString() : 'Could not reach the camera.',
            status: UiStatus.danger);
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _openSettings() {
    final s = _status;
    if (s == null) return;
    UiSheet.show<void>(
      context,
      title: 'Motion detection',
      subtitle: 'Changes apply on the camera at once.',
      child: _MotionSettings(client: _client, initial: s, onSaved: (v) {
        if (mounted) setState(() => _status = v);
      }),
    );
  }

  @override
  void dispose() {
    _retry?.cancel();
    _poll?.cancel();
    _afterControl?.cancel();
    _sub?.cancel();
    widget.platform.keepAwake(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _connect() {
    _sub?.cancel();
    _sub = _client.stream().listen(
      (f) {
        if (mounted) {
          setState(() {
            _frame = f;
            _problem = null;
          });
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        if (e is PinRejected) {
          setState(() {
            _fatal = true;
            _problem = e.toString();
          });
        } else {
          _scheduleRetry('Connection lost. Reconnecting...');
        }
      },
      onDone: () {
        if (mounted && !_fatal) _scheduleRetry('Connection closed. Reconnecting...');
      },
      cancelOnError: true,
    );
  }

  void _scheduleRetry(String message) {
    setState(() => _problem = message);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), () {
      if (mounted && !_fatal) _connect();
    });
  }

  void _openEvents() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EventsScreen(platform: widget.platform, camera: widget.camera),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: UiTheme.dark(),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _chrome = !_chrome),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_frame != null)
                Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.contain)
              else
                const Center(child: UiSpinner(size: 32)),
              if (_problem != null)
                Align(
                  alignment: Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.all(UiSpace.xl),
                    child: UiAlert(_problem!, status: _fatal ? UiStatus.danger : UiStatus.warning),
                  ),
                ),
              if (_chrome) ...[
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(UiSpace.sm),
                      child: Row(
                        children: [
                          UiIconButton(Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).pop()),
                          const SizedBox(width: UiSpace.sm),
                          Expanded(
                            child: Text(
                              widget.camera.name,
                              style: context.text.titleMedium?.copyWith(color: Colors.white),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (_frame != null && _problem == null) const UiStatusPill('Live', status: UiStatus.success, pulse: true),
                        ],
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(UiSpace.lg),
                      child: _controls(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    final s = _status;
    final canRecord = s != null && s.recordingAvailable && !s.recording;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (s != null)
          Wrap(
            spacing: UiSpace.sm,
            runSpacing: UiSpace.sm,
            alignment: WrapAlignment.center,
            children: [
              UiStatusPill(s.motion ? 'Motion' : 'No motion', status: s.motion ? UiStatus.warning : UiStatus.neutral),
              if (s.recording) const UiStatusPill('Recording', status: UiStatus.danger, pulse: true),
              if (s.torch) const UiStatusPill('Light on', status: UiStatus.info),
              if (s.autoRecord != null)
                UiStatusPill(s.autoRecord! ? 'Auto record on' : 'Auto record off',
                    status: s.autoRecord! ? UiStatus.accent : UiStatus.neutral),
            ],
          ),
        const SizedBox(height: UiSpace.md),
        Wrap(
          spacing: UiSpace.md,
          runSpacing: UiSpace.sm,
          alignment: WrapAlignment.center,
          children: [
            UiIconButton(
              Icons.cameraswitch_rounded,
              tooltip: 'Switch camera',
              variant: UiButtonVariant.secondary,
              size: UiSize.lg,
              circular: true,
              loading: _busy == 'switch',
              onPressed: s == null ? null : () => _send('switch', _client.switchCamera),
            ),
            if (s?.hasTorch ?? false)
              UiIconButton(
                s!.torch ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
                tooltip: s.torch ? 'Turn the light off' : 'Turn the light on',
                variant: s.torch ? UiButtonVariant.primary : UiButtonVariant.secondary,
                size: UiSize.lg,
                circular: true,
                loading: _busy == 'torch',
                onPressed: () => _send('torch', () => _client.setTorch(!s.torch)),
              ),
            UiIconButton(
              Icons.fiber_manual_record_rounded,
              tooltip: s != null && !s.recordingAvailable ? 'This camera cannot record clips' : 'Record a clip now',
              variant: UiButtonVariant.secondary,
              status: UiStatus.danger,
              size: UiSize.lg,
              circular: true,
              loading: _busy == 'record',
              onPressed: canRecord ? () => _send('record', _client.recordNow, done: 'Recording a ${s.clipSec} s clip.') : null,
            ),
            UiIconButton(
              Icons.tune_rounded,
              tooltip: 'Motion settings',
              variant: UiButtonVariant.secondary,
              size: UiSize.lg,
              circular: true,
              onPressed: s == null ? null : _openSettings,
            ),
            UiIconButton(
              Icons.history_rounded,
              tooltip: 'Events and clips',
              variant: UiButtonVariant.secondary,
              size: UiSize.lg,
              circular: true,
              onPressed: _openEvents,
            ),
          ],
        ),
      ],
    );
  }
}

/// Motion sliders for a remote camera. Each slider is sent when it is let go.
class _MotionSettings extends StatefulWidget {
  const _MotionSettings({required this.client, required this.initial, required this.onSaved});

  final CameraClient client;
  final RemoteStatus initial;
  final ValueChanged<RemoteStatus> onSaved;

  @override
  State<_MotionSettings> createState() => _MotionSettingsState();
}

class _MotionSettingsState extends State<_MotionSettings> {
  late bool? _auto = widget.initial.autoRecord;

  Future<void> _setAuto(bool on) async {
    final before = _auto;
    setState(() => _auto = on);
    try {
      final s = await widget.client.setAutoRecord(on);
      widget.onSaved(s);
      if (mounted) setState(() => _auto = s.autoRecord);
    } catch (e) {
      if (!mounted) return;
      setState(() => _auto = before);
      context.showToast(e is ControlFailed || e is PinRejected ? e.toString() : 'Could not reach the camera.',
          status: UiStatus.danger);
    }
  }

  late final Map<String, double> _v = {
    'sensitivity': widget.initial.sensitivity.toDouble(),
    'minArea': widget.initial.minArea.toDouble(),
    'cooldownSec': widget.initial.cooldownSec.toDouble(),
    'clipSec': widget.initial.clipSec.toDouble(),
  };

  Future<void> _save(String key, double v) async {
    try {
      widget.onSaved(await widget.client.updateSettings({key: v.round()}));
    } catch (e) {
      if (mounted) {
        context.showToast(e is ControlFailed || e is PinRejected ? e.toString() : 'Could not reach the camera.',
            status: UiStatus.danger);
      }
    }
  }

  Widget _slider(String key, String label, double min, double max, String Function(double) format) {
    return UiSlider(
      label: label,
      value: _v[key]!.clamp(min, max),
      min: min,
      max: max,
      divisions: (max - min).round(),
      format: format,
      onChanged: (v) => setState(() => _v[key] = v),
      onChangeEnd: (v) => _save(key, v),
    );
  }

  @override
  Widget build(BuildContext context) {
    return UiColumn(
      gap: UiSpace.md,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A camera on an older Watchman sends no autoRecord: it always records on motion.
        if (_auto != null)
          UiSwitchTile(
            'Auto record',
            subtitle: _auto! ? 'Motion records a clip.' : 'Off. Motion is only listed; press Record for a clip.',
            icon: Icons.fiber_manual_record_rounded,
            value: _auto!,
            onChanged: _setAuto,
          ),
        _slider('sensitivity', 'Sensitivity', 1, 100, (v) => '${v.round()}'),
        _slider('minArea', 'Ignore changes smaller than', 1, 30, (v) => '${v.round()}% of the picture'),
        _slider('cooldownSec', 'Wait between clips', 0, 120, (v) => '${v.round()} s'),
        _slider('clipSec', 'Clip length', 5, 60, (v) => '${v.round()} s'),
      ],
    );
  }
}
