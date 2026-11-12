package com.itsash.watchman

import android.content.Context
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicInteger

/**
 * Process-wide state of the camera side, shared by CameraService, the HTTP server and the activity
 * (they all run in the same process).
 */
object CameraEngine {
    private val lock = Object()

    @Volatile var running = false
    @Volatile var recording = false
    @Volatile var recordingAvailable = true
    @Volatile var facing = "back"
    @Volatile var lastMotionMs = 0L
    @Volatile var motionNow = false
    @Volatile var port = 0
    @Volatile var error: String? = null

    /** Number of HTTP clients that want frames (stream or snapshot). */
    val viewers = AtomicInteger(0)

    /** Set by MainActivity while the camera screen is open; receives each JPEG on the main thread. */
    @Volatile var previewSink: ((ByteArray) -> Unit)? = null

    @Volatile private var jpeg: ByteArray? = null
    @Volatile private var seq = 0L

    val wantsFrames: Boolean get() = viewers.get() > 0 || previewSink != null

    fun publish(bytes: ByteArray) {
        synchronized(lock) {
            jpeg = bytes
            seq++
            lock.notifyAll()
        }
        previewSink?.invoke(bytes)
    }

    fun currentSeq(): Long = seq

    /** Waits until a frame newer than [after] exists (or [timeoutMs] passes). Returns it with its sequence. */
    fun waitFrame(after: Long, timeoutMs: Long): Pair<ByteArray, Long>? {
        synchronized(lock) {
            if (seq <= after || jpeg == null) {
                try { lock.wait(timeoutMs) } catch (_: InterruptedException) {}
            }
            val j = jpeg
            return if (j != null && seq > after) j to seq else null
        }
    }

    fun wakeAll() = synchronized(lock) { lock.notifyAll() }

    fun reset() {
        synchronized(lock) { jpeg = null; seq = 0; lock.notifyAll() }
        recording = false
        motionNow = false
        error = null
        viewers.set(0)
    }

    fun addresses(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .filter { !it.isLoopbackAddress }
            .mapNotNull { it.hostAddress }
    } catch (_: Exception) {
        emptyList()
    }

    fun stateMap(ctx: Context): Map<String, Any?> {
        val p = WatchmanPrefs(ctx)
        return mapOf(
            "running" to running, "recording" to recording, "recordingAvailable" to recordingAvailable,
            "facing" to facing, "lastMotionMs" to lastMotionMs, "motion" to motionNow,
            "viewers" to viewers.get(), "port" to port, "addresses" to addresses(),
            "pin" to p.pin, "name" to p.cameraName, "error" to error,
        )
    }

    /** Public status for viewers (/status). Never includes the PIN. */
    fun statusJson(ctx: Context, events: EventStore): JSONObject {
        val p = WatchmanPrefs(ctx)
        return JSONObject()
            .put("app", "watchman").put("name", p.cameraName).put("facing", facing)
            .put("recording", recording).put("motion", motionNow).put("lastMotionMs", lastMotionMs)
            .put("viewers", viewers.get()).put("audio", p.audio)
            .put("lastEventId", events.since(0).let { a -> if (a.length() == 0) 0 else a.getJSONObject(a.length() - 1).optLong("id") })
            .put("now", System.currentTimeMillis())
    }
}
