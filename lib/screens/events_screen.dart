import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../logic/camera_client.dart';
import '../logic/models.dart';
import '../logic/rules.dart';
import '../platform/watchman_platform.dart';
import 'clip_player_screen.dart';

/// Motion events of a camera, with play and download for the recorded clips.
class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key, required this.platform, required this.camera});

  final WatchmanPlatform platform;
  final SavedCamera camera;

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  late final CameraClient _client = CameraClient(host: widget.camera.host, port: widget.camera.port, pin: widget.camera.pin);
  List<MotionEvent>? _events;
  Map<String, ClipInfo> _clips = const {};
  String? _error;
  String? _downloading;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final events = await _client.events();
      final clips = await _client.clips();
      if (!mounted) return;
      setState(() {
        _events = events;
        _clips = {for (final c in clips) c.name: c};
      });
    } on PinRejected catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the camera.');
    }
  }

  void _play(String clip, DateTime time) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ClipPlayerScreen(
        url: _client.clipUrl(clip),
        title: Fmt.when(time),
        actions: [UiIconButton(Icons.download_rounded, tooltip: 'Download', onPressed: () => _download(clip))],
      ),
    ));
  }

  Future<void> _download(String clip) async {
    if (_downloading != null) return;
    setState(() {
      _downloading = clip;
      _progress = 0;
    });
    try {
      final dir = await widget.platform.downloadDir();
      final file = await _client.download(clip, dir, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) context.showToast('Saved to ${file.path}', status: UiStatus.success, duration: const Duration(seconds: 6));
    } catch (_) {
      if (mounted) context.showToast('Download failed.', status: UiStatus.danger);
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    final referenced = {for (final e in events ?? const <MotionEvent>[]) if (e.clip != null) e.clip!};
    final extra = _clips.values.where((c) => !referenced.contains(c.name)).toList()..sort((a, b) => b.time.compareTo(a.time));
    return UiScaffold(
      appBar: UiAppBar(
        title: widget.camera.name,
        actions: [UiIconButton(Icons.refresh_rounded, tooltip: 'Refresh', onPressed: _load)],
      ),
      scrollable: events != null && (events.isNotEmpty || extra.isNotEmpty),
      body: _error != null
          ? UiErrorState(message: _error!, onRetry: _load)
          : events == null
          ? const Center(child: UiSpinner())
          : events.isEmpty && extra.isEmpty
          ? const UiEmptyState(title: 'No motion yet', message: 'Events and clips from this camera show up here.', icon: Icons.sensors_rounded)
          : UiColumn(
              gap: UiSpace.lg,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (events.isNotEmpty)
                  UiListGroup(
                    header: 'Motion events',
                    children: [
                      for (final e in events)
                        UiListTile(
                          Fmt.when(e.time),
                          subtitle: e.clip == null
                              ? '${e.score.toStringAsFixed(1)}% of the picture moved · no clip'
                              : '${e.score.toStringAsFixed(1)}% of the picture moved · ${Fmt.bytes(_clips[e.clip]?.size ?? 0)}',
                          icon: e.clip == null ? Icons.sensors_rounded : Icons.play_circle_rounded,
                          iconStatus: e.clip == null ? UiStatus.neutral : UiStatus.accent,
                          onTap: e.clip == null ? null : () => _play(e.clip!, e.time),
                          trailing: e.clip == null
                              ? null
                              : _downloading == e.clip
                              ? SizedBox(width: 56, child: UiProgressBar(_progress))
                              : UiIconButton(Icons.download_rounded, tooltip: 'Download', onPressed: () => _download(e.clip!)),
                        ),
                    ],
                  ),
                if (extra.isNotEmpty)
                  UiListGroup(
                    header: 'Other clips',
                    children: [
                      for (final c in extra)
                        UiListTile(
                          Fmt.when(c.time),
                          subtitle: Fmt.bytes(c.size),
                          icon: Icons.movie_rounded,
                          onTap: () => _play(c.name, c.time),
                          trailing: UiIconButton(Icons.download_rounded, tooltip: 'Download', onPressed: () => _download(c.name)),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}
