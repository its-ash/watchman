import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import 'platform/watchman_platform.dart';
import 'screens/mode_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(WatchmanApp(platform: MethodChannelWatchmanPlatform()));
}

class WatchmanApp extends StatelessWidget {
  const WatchmanApp({super.key, required this.platform});

  final WatchmanPlatform platform;

  @override
  Widget build(BuildContext context) {
    return UiApp(
      title: 'Watchman',
      home: ModeScreen(platform: platform),
    );
  }
}
