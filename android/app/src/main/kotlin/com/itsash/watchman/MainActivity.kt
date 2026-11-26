package com.itsash.watchman

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Flutter host. Channel contract is documented in CLAUDE.md. */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var prefs: WatchmanPrefs
    private lateinit var events: EventStore
    private lateinit var clips: ClipStore
    private var discovery: Discovery? = null
    private var discoverySink: EventChannel.EventSink? = null
    private var pendingPermission: MethodChannel.Result? = null

    private fun permissionName(key: String): String? = when (key) {
        "camera" -> Manifest.permission.CAMERA
        "microphone" -> Manifest.permission.RECORD_AUDIO
        "notifications" -> if (Build.VERSION.SDK_INT >= 33) Manifest.permission.POST_NOTIFICATIONS else null
        else -> null
    }

    private fun granted(key: String): Boolean {
        val p = permissionName(key) ?: return true // not needed on this Android version
        return ContextCompat.checkSelfPermission(this, p) == PackageManager.PERMISSION_GRANTED
    }

    private fun permissionMap() =
        mapOf("camera" to granted("camera"), "microphone" to granted("microphone"), "notifications" to granted("notifications"))

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        prefs = WatchmanPrefs(this)
        events = EventStore.get(this)
        clips = ClipStore(prefs, events)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "com.itsash.watchman/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "getConfig" -> result.success(prefs.toMap())
                "setConfig" -> {
                    val key = call.argument<String>("key")!!
                    prefs.set(key, call.argument<Any>("value"))
                    // Facing / audio changes need the camera rebound; the rest is read live.
                    if (key == "facing" || key == "audio") CameraService.send(this, CameraService.ACTION_REBIND)
                    result.success(null)
                }
                "permissionStatus" -> result.success(permissionMap())
                "requestPermissions" -> {
                    val keys = call.argument<List<String>>("names") ?: emptyList()
                    val needed = keys.filter { !granted(it) }.mapNotNull { permissionName(it) }
                    if (needed.isEmpty()) {
                        result.success(permissionMap())
                    } else {
                        pendingPermission?.success(permissionMap())
                        pendingPermission = result
                        ActivityCompat.requestPermissions(this, needed.toTypedArray(), 77)
                    }
                }
                "startCamera" -> {
                    if (!granted("camera")) {
                        result.error("permission", "Camera permission is needed.", null)
                    } else {
                        CameraService.start(this)
                        result.success(null)
                    }
                }
                "stopCamera" -> {
                    CameraService.send(this, CameraService.ACTION_STOP)
                    result.success(null)
                }
                "switchCamera" -> {
                    if (CameraEngine.running) CameraService.send(this, CameraService.ACTION_SWITCH)
                    else prefs.facing = if (prefs.facing == "front") "back" else "front"
                    result.success(null)
                }
                "cameraState" -> result.success(CameraEngine.stateMap(this))
                "regeneratePin" -> {
                    prefs.pin = PinGuard.generate()
                    result.success(prefs.pin)
                }
                "listClips" -> result.success(
                    clips.list().map { mapOf("name" to it.name, "size" to it.sizeBytes, "ts" to it.modifiedMs) }
                )
                "deleteClip" -> result.success(clips.delete(call.argument<String>("name") ?: ""))
                "deleteAllClips" -> {
                    clips.deleteAll()
                    result.success(null)
                }
                "localEvents" -> result.success(events.since(0).toString())
                "clearEvents" -> {
                    events.clear()
                    result.success(null)
                }
                "enforceLimit" -> {
                    clips.enforceLimit()
                    result.success(null)
                }
                "savedCameras" -> result.success(prefs.savedCameras)
                "saveCameras" -> {
                    prefs.savedCameras = call.argument<String>("json") ?: "[]"
                    MonitorService.sync(this)
                    result.success(null)
                }
                "downloadDir" -> {
                    val d = getExternalFilesDir("Movies") ?: filesDir
                    d.mkdirs()
                    result.success(d.absolutePath)
                }
                "setDim" -> {
                    val on = call.argument<Boolean>("on") == true
                    val lp = window.attributes
                    lp.screenBrightness = if (on) 0.01f else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    window.attributes = lp
                    result.success(null)
                }
                "keepAwake" -> {
                    if (call.argument<Boolean>("on") == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "com.itsash.watchman/preview").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                CameraEngine.previewSink = { bytes -> main.post { sink.success(bytes) } }
            }

            override fun onCancel(args: Any?) {
                CameraEngine.previewSink = null
            }
        })

        EventChannel(messenger, "com.itsash.watchman/discovery").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                discoverySink = sink
                discovery = Discovery(this@MainActivity) { list -> discoverySink?.success(list) }.also { it.start() }
            }

            override fun onCancel(args: Any?) {
                discovery?.stop()
                discovery = null
                discoverySink = null
            }
        })
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 77) {
            pendingPermission?.success(permissionMap())
            pendingPermission = null
        }
    }

    override fun onDestroy() {
        CameraEngine.previewSink = null
        discovery?.stop()
        super.onDestroy()
    }
}
