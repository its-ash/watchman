# Watchman

Turn an old phone into a home security camera on your Wi-Fi. No cloud, no account.

**[Website](https://watchman.itsash.in)** · **[Download APK](https://github.com/its-ash/watchman/releases/latest/download/watchman.apk)** · Get it in **[Ash Store](https://store.itsash.in)**

## Features

- **Two modes.** Camera: the old phone watches. Viewer: your own phone watches it.
- **Motion detection.** Compares small grayscale copies of the picture. Sensitivity, "ignore small changes" and a cooldown between clips are adjustable.
- **Clips.** Press Record for a short clip (5 to 60 s) with a timestamp. Turn on **Auto record** and motion records one by itself (off by default: motion is then only listed). Optional sound. Delete clips, or set a storage limit and the oldest are removed first.
- **Live view.** Full-screen MJPEG stream over your Wi-Fi, protected by a 4 to 6 digit PIN shown on the camera phone.
- **Finds cameras by itself** with mDNS (`_watchman._tcp`), or add one by IP address.
- **Watch in any browser.** Open `http://<camera-ip>:8765/` on a phone or computer on the same Wi-Fi and enter the PIN. No app needed on that device.
- **Remote controls, in the app and in the browser.** Switch front/back camera, turn the light on, record a clip now, take a snapshot, and change the motion settings.
- **Events and clips on the viewer.** See the motion list, play, download or delete any clip.
- **Monitor.** Turn it on and the viewer notifies you when a camera sees motion, even with the app closed.
- **Keeps working with the screen off** (foreground service). Optional dim screen while watching.
- Everything stays on your local network.

## Install

- **Ash Store**: install [Ash Store](https://store.itsash.in) once, then install and update Watchman from it.
- **APK**: download the [latest APK](https://github.com/its-ash/watchman/releases/latest/download/watchman.apk) on your phone and open it. Allow your browser to install unknown apps if Android asks.

Requires Android 8.0 (API 26) or newer. Both phones must be on the same Wi-Fi.

## Develop

Needs Flutter ≥ 3.44 and the shared theme package at `../theme`.

```bash
make run          # run on a connected device
make build        # release APK
make test         # flutter analyze + flutter test
make test-native  # Kotlin JVM unit tests (motion, PIN, storage); run make build once first
make deploy       # bump version, build, tag, push, GitHub release (see store.mk)
```

## Release

`make deploy` follows the Ash Store kit (`store.mk`, `store.json`): it bumps the
version in `pubspec.yaml`, builds, commits, tags `vX.Y.Z`, pushes, and publishes
a GitHub release with `watchman.apk`. Ash Store and the website pick up the new
version from that release.

## Project layout

```
lib/
  main.dart                 app entry (UiApp)
  logic/                    pure Dart: models, rules (PIN, storage, addresses), MJPEG parser, HTTP client
  platform/                 WatchmanPlatform interface + MethodChannel implementation
  screens/                  mode, camera, camera clips, viewer, live, events, clip player, settings
android/app/src/main/kotlin/com/itsash/watchman/
  CameraService.kt          foreground service: CameraX, motion, clips, server, NSD
  MotionDetector.kt         pure motion diff + cooldown gate
  PinGuard.kt               pure PIN check with lockout
  StoragePolicy.kt          pure storage limit rule
  WatchmanServer.kt         HTTP server (stream, snapshot, status, events, clips)
  MonitorService.kt         viewer background monitor + notifications
  Discovery.kt              NSD discovery
  MainActivity.kt           channels
assets/icon/                pixel-art icon sources
test/                       Dart tests; android/app/src/test has Kotlin tests
```

## License

All rights reserved.

Built by [itsash.in](https://itsash.in).
