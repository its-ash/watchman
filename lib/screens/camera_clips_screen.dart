import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../logic/models.dart';
import '../logic/rules.dart';
import '../platform/watchman_platform.dart';
import 'clip_player_screen.dart';

/// Clips recorded by this phone, with delete. Playing a clip needs the camera running, because the
/// phone plays it from its own local server.
class CameraClipsScreen extends StatefulWidget {
  const CameraClipsScreen({super.key, required this.platform});

  final WatchmanPlatform platform;

  @override
  State<CameraClipsScreen> createState() => _CameraClipsScreenState();
}

class _CameraClipsScreenState extends State<CameraClipsScreen> {
  List<ClipInfo>? _clips;
  Map<String, MotionEvent> _byClip = const {};
  CameraState _state = const CameraState();
  CameraConfig _config = const CameraConfig();

  WatchmanPlatform get _p => widget.platform;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final clips = await _p.listClips();
    final events = await _p.localEvents();
    final state = await _p.cameraState();
    final config = await _p.getConfig();
    if (!mounted) return;
    setState(() {
      _clips = clips;
      _byClip = {for (final e in events) if (e.clip != null) e.clip!: e};
      _state = state;
      _config = config;
    });
  }

  void _play(ClipInfo c) {
    final port = _state.port;
    if (!_state.running || port == 0) {
      context.showToast('Start watching to play clips on this phone.', status: UiStatus.info);
      return;
    }
    final url = Uri(scheme: 'http', host: '127.0.0.1', port: port, path: '/clips/${c.name}', queryParameters: {'pin': _config.pin});
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ClipPlayerScreen(url: url.toString(), title: Fmt.when(c.time))));
  }

  Future<void> _delete(ClipInfo c) async {
    final ok = await UiDialog.confirm(context, title: 'Delete this clip?', message: Fmt.when(c.time), destructive: true, confirmLabel: 'Delete');
    if (!ok) return;
    await _p.deleteClip(c.name);
    _load();
  }

  Future<void> _deleteAll() async {
    final ok = await UiDialog.confirm(
      context,
      title: 'Delete all clips?',
      message: 'This removes every recorded clip from this phone.',
      destructive: true,
      confirmLabel: 'Delete all',
    );
    if (!ok) return;
    await _p.deleteAllClips();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final clips = _clips;
    final total = clips?.fold<int>(0, (a, c) => a + c.size) ?? 0;
    return UiScaffold(
      appBar: UiAppBar(
        title: 'Clips',
        actions: [
          if (clips != null && clips.isNotEmpty)
            UiIconButton(Icons.delete_sweep_rounded, tooltip: 'Delete all', onPressed: _deleteAll),
        ],
      ),
      scrollable: clips != null && clips.isNotEmpty,
      body: clips == null
          ? const Center(child: UiSpinner())
          : clips.isEmpty
          ? const UiEmptyState(
              title: 'No clips yet',
              message: 'When motion is detected, a short clip is recorded here.',
              icon: Icons.videocam_off_rounded,
            )
          : UiColumn(
              gap: UiSpace.md,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${clips.length} clips, ${Fmt.bytes(total)}. Limit: ${StorageLimits.label(_config.storageMb)}. '
                  'The oldest clips are deleted first when the limit is reached.',
                  style: context.text.bodySmall?.copyWith(color: context.colors.textMuted),
                ),
                UiListGroup(
                  children: [
                    for (final c in clips)
                      UiListTile(
                        Fmt.when(c.time),
                        subtitle: _byClip[c.name] == null
                            ? Fmt.bytes(c.size)
                            : '${Fmt.bytes(c.size)} · ${_byClip[c.name]!.score.toStringAsFixed(1)}% of the picture moved',
                        icon: Icons.play_circle_rounded,
                        onTap: () => _play(c),
                        trailing: UiIconButton(Icons.delete_outline_rounded, tooltip: 'Delete', onPressed: () => _delete(c)),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}
