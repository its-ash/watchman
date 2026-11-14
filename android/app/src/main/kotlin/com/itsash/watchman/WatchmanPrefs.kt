package com.itsash.watchman

import android.content.Context
import android.content.SharedPreferences
import java.io.File

/** Settings shared by the activity and the services. */
class WatchmanPrefs(context: Context) {
    private val ctx = context.applicationContext
    private val sp: SharedPreferences = ctx.getSharedPreferences("watchman_prefs", Context.MODE_PRIVATE)

    var pin: String
        get() {
            val saved = sp.getString("pin", null)
            if (PinGuard.isValidPin(saved)) return saved!!
            return PinGuard.generate().also { sp.edit().putString("pin", it).apply() }
        }
        set(v) = sp.edit().putString("pin", v).apply()

    var port: Int
        get() = sp.getInt("port", 8765)
        set(v) = sp.edit().putInt("port", v).apply()

    var facing: String // "back" | "front"
        get() = sp.getString("facing", "back") ?: "back"
        set(v) = sp.edit().putString("facing", v).apply()

    var audio: Boolean
        get() = sp.getBoolean("audio", false)
        set(v) = sp.edit().putBoolean("audio", v).apply()

    var dim: Boolean
        get() = sp.getBoolean("dim", true)
        set(v) = sp.edit().putBoolean("dim", v).apply()

    /** Record a clip when motion is seen. Off: motion is only listed; clips come from Record (app or web). */
    var autoRecord: Boolean
        get() = sp.getBoolean("autoRecord", false)
        set(v) = sp.edit().putBoolean("autoRecord", v).apply()

    var sensitivity: Int
        get() = sp.getInt("sensitivity", 60)
        set(v) = sp.edit().putInt("sensitivity", v.coerceIn(1, 100)).apply()

    /** Smallest changed share of the picture (percent) that counts as motion. */
    var minArea: Int
        get() = sp.getInt("minArea", 2)
        set(v) = sp.edit().putInt("minArea", v.coerceIn(1, 30)).apply()

    var cooldownSec: Int
        get() = sp.getInt("cooldownSec", 10)
        set(v) = sp.edit().putInt("cooldownSec", v.coerceIn(0, 300)).apply()

    var clipSec: Int
        get() = sp.getInt("clipSec", 15)
        set(v) = sp.edit().putInt("clipSec", v.coerceIn(5, 60)).apply()

    /** Storage limit for clips in MB. 0 = unlimited. */
    var storageMb: Int
        get() = sp.getInt("storageMb", 500)
        set(v) = sp.edit().putInt("storageMb", v.coerceAtLeast(0)).apply()

    var cameraName: String
        get() = sp.getString("cameraName", null) ?: android.os.Build.MODEL ?: "Camera"
        set(v) = sp.edit().putString("cameraName", v.take(30)).apply()

    /** Viewer: saved cameras as a JSON array of {name, host, port, pin, monitor}. Dart owns the shape. */
    var savedCameras: String
        get() = sp.getString("savedCameras", "[]") ?: "[]"
        set(v) = sp.edit().putString("savedCameras", v).apply()

    fun clipsDir(): File = File(ctx.filesDir, "clips").also { it.mkdirs() }

    fun toMap(): Map<String, Any> = mapOf(
        "facing" to facing, "audio" to audio, "dim" to dim, "autoRecord" to autoRecord, "sensitivity" to sensitivity,
        "minArea" to minArea, "cooldownSec" to cooldownSec, "clipSec" to clipSec,
        "storageMb" to storageMb, "cameraName" to cameraName, "pin" to pin, "port" to port,
    )

    fun set(key: String, value: Any?) {
        when (key) {
            "facing" -> facing = if (value == "front") "front" else "back"
            "audio" -> audio = value == true
            "dim" -> dim = value == true
            "autoRecord" -> autoRecord = value == true
            "sensitivity" -> sensitivity = (value as Number).toInt()
            "minArea" -> minArea = (value as Number).toInt()
            "cooldownSec" -> cooldownSec = (value as Number).toInt()
            "clipSec" -> clipSec = (value as Number).toInt()
            "storageMb" -> storageMb = (value as Number).toInt()
            "cameraName" -> cameraName = (value as String).trim().ifEmpty { "Camera" }
            "pin" -> if (PinGuard.isValidPin(value as? String)) pin = value as String
        }
    }
}
