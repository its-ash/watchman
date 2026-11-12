import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:theme/theme.dart';

import '../logic/camera_client.dart';
import '../logic/models.dart';
import '../platform/watchman_platform.dart';
import 'events_screen.dart';

/// Full-screen live view (MJPEG) of one camera. Reconnects by itself when the connection drops.
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
  Uint8List? _frame;
  String? _problem;
  bool _fatal = false;
  bool _chrome = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    widget.platform.keepAwake(true);
    _connect();
  }

  @override
  void dispose() {
    _retry?.cancel();
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
    return Scaffold(
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
                    child: UiButton('Events and clips', icon: Icons.history_rounded, onPressed: _openEvents),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
