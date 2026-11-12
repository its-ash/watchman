package com.itsash.watchman

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.app.Service
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import java.net.HttpURLConnection
import java.net.URL
import java.text.DateFormat
import java.util.Date

/**
 * Viewer "Monitor": while on, polls every saved camera marked monitor=true for new motion events
 * every few seconds and shows a notification for each. Runs as a foreground service so it keeps
 * polling when the app is in the background. Holds a partial wake lock only while it runs.
 */
class MonitorService : Service() {
    companion object {
        const val ACTION_STOP = "com.itsash.watchman.MONITOR_STOP"
        private const val CH_STATUS = "monitor"
        private const val CH_ALERT = "motion"
        private const val NOTIF_ID = 21
        private const val POLL_MS = 5000L

        /** Starts the service if any saved camera is monitored, stops it otherwise. */
        fun sync(ctx: Context) {
            val want = monitored(WatchmanPrefs(ctx)).isNotEmpty()
            val i = Intent(ctx, MonitorService::class.java)
            if (want) ContextCompat.startForegroundService(ctx, i) else ctx.stopService(i)
        }

        private data class Target(val name: String, val host: String, val port: Int, val pin: String)

        private fun monitored(prefs: WatchmanPrefs): List<Target> = try {
            val arr = JSONArray(prefs.savedCameras)
            (0 until arr.length()).map { arr.getJSONObject(it) }
                .filter { it.optBoolean("monitor") }
                .map { Target(it.optString("name", "Camera"), it.getString("host"), it.optInt("port", 8765), it.optString("pin")) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    @Volatile private var alive = false
    private var thread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val lastIds = HashMap<String, Long>()
    private var nextAlert = 100

    override fun onBind(intent: Intent?): IBinder? = null

    @SuppressLint("WakelockTimeout")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // The Stop button also switches Monitor off for every camera.
            try {
                val p = WatchmanPrefs(this)
                val arr = JSONArray(p.savedCameras)
                for (i in 0 until arr.length()) arr.getJSONObject(i).put("monitor", false)
                p.savedCameras = arr.toString()
            } catch (_: Exception) {}
            stopSelf()
            return START_NOT_STICKY
        }
        if (alive) return START_STICKY
        createChannels()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIF_ID, status("Monitoring cameras"), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIF_ID, status("Monitoring cameras"))
            }
        } catch (_: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        alive = true
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "watchman:monitor").apply { acquire() }
        thread = Thread({ loop() }, "watchman-monitor").also { it.isDaemon = true; it.start() }
        return START_STICKY
    }

    private fun loop() {
        val prefs = WatchmanPrefs(this)
        while (alive) {
            val targets = monitored(prefs)
            if (targets.isEmpty()) {
                stopSelf()
                return
            }
            val unreachable = ArrayList<String>()
            for (t in targets) {
                try {
                    poll(t)
                } catch (_: Exception) {
                    unreachable.add(t.name)
                }
            }
            val text = if (unreachable.isEmpty()) "Watching ${targets.size} camera(s) for motion"
            else "Cannot reach: " + unreachable.joinToString()
            getSystemService(NotificationManager::class.java).notify(NOTIF_ID, status(text))
            try { Thread.sleep(POLL_MS) } catch (_: InterruptedException) { return }
        }
    }

    private fun poll(t: Target) {
        val key = "${t.host}:${t.port}"
        val since = lastIds[key] ?: -1L
        val conn = URL("http://${t.host}:${t.port}/events?since=${if (since < 0) 0 else since}").openConnection() as HttpURLConnection
        conn.connectTimeout = 4000
        conn.readTimeout = 4000
        conn.setRequestProperty("X-Pin", t.pin)
        try {
            if (conn.responseCode != 200) throw IllegalStateException("http ${conn.responseCode}")
            val arr = JSONArray(conn.inputStream.bufferedReader().readText())
            var maxId = since.coerceAtLeast(0)
            var newest = 0L
            var count = 0
            for (i in 0 until arr.length()) {
                val e = arr.getJSONObject(i)
                maxId = maxOf(maxId, e.optLong("id"))
                newest = maxOf(newest, e.optLong("ts"))
                count++
            }
            // First poll only sets the baseline, so old events do not notify.
            if (since >= 0 && count > 0) alert(t, newest, count)
            lastIds[key] = maxId
        } finally {
            conn.disconnect()
        }
    }

    private fun alert(t: Target, ts: Long, count: Int) {
        val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ts))
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(this, CH_ALERT)
            .setSmallIcon(R.drawable.ic_stat_watch)
            .setContentTitle("Motion at ${t.name}")
            .setContentText(if (count > 1) "$count events, latest at $time" else "Detected at $time")
            .setAutoCancel(true)
            .setContentIntent(open)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        getSystemService(NotificationManager::class.java).notify(nextAlert++, n)
    }

    private fun createChannels() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH_STATUS, "Monitoring", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel(CH_ALERT, "Motion alerts", NotificationManager.IMPORTANCE_HIGH))
    }

    private fun status(text: String): Notification {
        val stop = PendingIntent.getService(
            this, 2, Intent(this, MonitorService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CH_STATUS)
            .setSmallIcon(R.drawable.ic_stat_watch)
            .setContentTitle("Watchman monitor")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(0, "Stop", stop)
            .build()
    }

    override fun onDestroy() {
        alive = false
        thread?.interrupt()
        try { wakeLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        super.onDestroy()
    }
}
