import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../platform/watchman_platform.dart';
import 'camera_screen.dart';
import 'settings_screen.dart';
import 'viewer_screen.dart';

/// First screen: this phone is the camera, or it watches another phone.
class ModeScreen extends StatelessWidget {
  const ModeScreen({super.key, required this.platform});

  final WatchmanPlatform platform;

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    return UiScaffold(
      appBar: UiAppBar(
        title: 'Watchman',
        actions: [
          UiIconButton(
            Icons.settings_rounded,
            tooltip: 'Settings',
            onPressed: () => _open(context, SettingsScreen(platform: platform)),
          ),
        ],
      ),
      scrollable: true,
      body: UiColumn(
        gap: UiSpace.lg,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('What should this phone do?', style: context.text.titleLarge),
          Text(
            'Turn an old phone into a security camera, and watch it from your own phone. '
            'Everything stays on your Wi-Fi: no cloud, no account.',
            style: context.text.bodyMedium?.copyWith(color: context.colors.textMuted),
          ),
          UiCard(
            onTap: () => _open(context, CameraScreen(platform: platform)),
            child: Row(
              children: [
                const UiIconBox(Icons.videocam_rounded, status: UiStatus.accent),
                const SizedBox(width: UiSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Camera', style: context.text.titleMedium),
                      Text(
                        'This phone watches. It detects motion, records clips and shows a live view to your other phone.',
                        style: context.text.bodySmall?.copyWith(color: context.colors.textMuted),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
          UiCard(
            onTap: () => _open(context, ViewerScreen(platform: platform)),
            child: Row(
              children: [
                const UiIconBox(Icons.visibility_rounded, status: UiStatus.info),
                const SizedBox(width: UiSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Viewer', style: context.text.titleMedium),
                      Text(
                        'Watch another phone. See the live picture, motion events and recorded clips.',
                        style: context.text.bodySmall?.copyWith(color: context.colors.textMuted),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
