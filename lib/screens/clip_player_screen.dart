import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

/// Plays one clip from a URL (the camera's HTTP server).
class ClipPlayerScreen extends StatelessWidget {
  const ClipPlayerScreen({super.key, required this.url, required this.title, this.actions = const []});

  final String url;
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return UiScaffold(
      appBar: UiAppBar(title: title, actions: actions),
      body: Center(child: UiVideoPlayer(url, autoPlay: true)),
    );
  }
}
