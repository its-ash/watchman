# Watchman (package: watchman / com.itsash.watchman)

Old phone as a home security camera on the local Wi-Fi. No cloud, no account. Camera mode watches, detects
motion, records clips and serves a live MJPEG stream and JSON over HTTP, PIN protected, advertised with NSD
(`_watchman._tcp`). Viewer mode finds cameras, shows the live view, events and clips, and can monitor in the
background. Kotlin owns the camera, server and services; Flutter is the UI.

## Code layout

- `android/app/src/main/kotlin/com/itsash/watchman/`
  - `MotionDetector.kt`: pure. `downscaleLuma` (Y plane to 64x48 grid, honours strides), `MotionDetector`
    (sensitivity 1..100 sets the brightness step, `minAreaPercent` ignores small changes, 2 warm-up frames),
    `MotionGate` (cooldown, no trigger while recording). Tests: `src/test/.../LogicTest.kt`.
  - `PinGuard.kt`: pure. PIN format (4-6 digits), generation, constant-time check, 5 wrong tries lock a client
    IP for 60 s (a request with no PIN is not a guess).
  - `StoragePolicy.kt`: pure. Oldest-first deletion down to the limit (newest clip always kept), safe clip name regex.
  - `CameraService.kt`: `LifecycleService`, foreground type `camera` (+ `microphone` when audio is on and granted).
    CameraX `ImageAnalysis` (640x480, YUV) + `VideoCapture` (SD). No Preview use case: JPEG frames are made from
    the analysis image only while someone wants them (`CameraEngine.wantsFrames`). Falls back to analysis only
    when the phone cannot bind both (`recordingAvailable=false`: events still logged, no clips). Partial wake lock
    and Wi-Fi lock only while running. Stop: notification action or app.
  - `CameraEngine.kt`: process-wide state (running, recording, latest JPEG + sequence, viewer count, preview sink).
  - `WatchmanServer.kt`: plain `ServerSocket` HTTP/1.1. Routes: `/hello` (no PIN), `/status`, `/events?since=N`,
    `/clips`, `/clips/<name>.mp4` (Range), `/snapshot.jpg`, `/stream` (multipart/x-mixed-replace, part header has
    Content-Length). PIN as header `X-Pin` or query `pin`.
  - `MonitorService.kt`: viewer foreground service (`specialUse`), polls `/events` of saved cameras with
    `monitor=true` every 5 s, notification per new event. First poll only sets the baseline. Its Stop action
    clears the monitor flags.
  - `Discovery.kt`: NSD discovery with a multicast lock, resolves one service at a time.
  - `WatchmanPrefs.kt` (SharedPreferences `watchman_prefs`), `EventStore.kt` (`events.json`, newest 200),
    `ClipStore.kt` (`filesDir/clips`, limit enforcement), `MainActivity.kt` (channels).
- `lib/logic/`: pure Dart, tested. `models`, `rules` (PinRules, StorageLimits, Addresses, Fmt), `mjpeg_parser`,
  `camera_client` (HTTP client for the viewer; tested against a local fake server).
- `lib/platform/watchman_platform.dart`: `WatchmanPlatform` interface (fakes in tests) + channel implementation.
- `lib/screens/`: `mode_screen` (first screen), `camera_screen`, `camera_clips_screen`, `viewer_screen`,
  `live_screen`, `events_screen`, `clip_player_screen`, `settings_screen` (ends with `UiAppearanceSection`,
  `UiUpdateSection(storeId: 'watchman')`, `UiDeveloperSection`).

## Channel contract

MethodChannel `com.itsash.watchman/control`: `getConfig`, `setConfig{key,value}` (facing, audio, dim, sensitivity,
minArea, cooldownSec, clipSec, storageMb, cameraName, pin), `permissionStatus`, `requestPermissions{names}`
(camera, microphone, notifications), `startCamera`, `stopCamera`, `switchCamera`, `cameraState`, `regeneratePin`,
`listClips`, `deleteClip{name}`, `deleteAllClips`, `localEvents`, `clearEvents`, `enforceLimit`, `savedCameras`,
`saveCameras{json}` (also starts/stops the monitor), `downloadDir`, `setDim{on}`, `keepAwake{on}`.
EventChannel `.../preview` (JPEG bytes, only while listened), `.../discovery` (list of {name, host, port}).

## Commands

- `make run`, `make build`, `make test` (analyze + Dart tests), `make test-native` (Kotlin JVM tests, needs one
  `make build` first), `make clean`.
- Icon: `assets/icon/*.svg` -> `rsvg-convert -w 1024 -h 1024` to `*-1024.png`, then `dart run flutter_launcher_icons`.

## Conventions

- minSdk 26. UI only from `../theme` (read `../theme/COMPONENTS.md`).
- The camera serves plain HTTP on the LAN, so the manifest sets `usesCleartextTraffic="true"` (video player,
  monitor). The PIN is the only protection; do not expose the port to the internet.
- Clip playback on the camera phone itself goes through its own server (`127.0.0.1`), so the camera must be running.

## Release (Ash Store)

- `store.json` (id `watchman`, repo its-ash/watchman), `store.mk`, `index.html` + `CNAME` (`watchman.itsash.in`).
  See `../ash-store/store-kit/STORE.md`.
- `make deploy` = bump version -> build -> commit, tag `vX.Y.Z`, push -> GitHub release with `watchman.apk` ->
  topics, homepage, Pages. Never create releases, tags or asset names by hand.
- Do not edit `store.mk` here. Edit `../ash-store/store-kit/store.mk`, then run `make store-sync` at the workspace root.
