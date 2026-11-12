import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchman/main.dart';

import 'package:watchman/logic/models.dart';
import 'package:watchman/platform/watchman_platform.dart';

class _FakePlatform implements WatchmanPlatform {
  @override
  noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getConfig) return Future.value(const CameraConfig());
    if (invocation.memberName == #cameraState) return Future.value(const CameraState());
    if (invocation.memberName == #permissionStatus) return Future.value(<String, bool>{});
    return Future<void>.value();
  }
}

void main() {
  testWidgets('first screen offers Camera and Viewer and a settings icon', (tester) async {
    await tester.pumpWidget(WatchmanApp(platform: _FakePlatform()));
    await tester.pump();
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Viewer'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    // Camera mode idle screen: explains what is needed and offers to start.
    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Start watching'), findsOneWidget);
    expect(find.text('What Watchman needs'), findsOneWidget);
    // Leave the screen so its status timer is cancelled.
    await tester.pumpWidget(const SizedBox());
  });
}
