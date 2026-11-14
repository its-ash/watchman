package com.itsash.watchman

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Matrix
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Size
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import java.io.ByteArrayOutputStream
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Camera mode. A foreground service (type camera, plus microphone when audio is on) owns the camera, so
 * watching continues with the screen off. It analyses frames for motion, records clips, produces JPEG
 * frames for the preview and the MJPEG stream, runs the HTTP server and advertises it with NSD.
 * A partial wake lock is held only while this service is running.
 */
class CameraService : LifecycleService() {
    companion object {
        const val ACTION_START = "com.itsash.watchman.START"
        const val ACTION_STOP = "com.itsash.watchman.STOP"
        const val ACTION_SWITCH = "com.itsash.watchman.SWITCH"
        const val ACTION_REBIND = "com.itsash.watchman.REBIND"
        const val ACTION_TORCH = "com.itsash.watchman.TORCH"
        const val ACTION_RECORD = "com.itsash.watchman.RECORD"
        private const val CHANNEL = "watching"
        private const val NOTIF_ID = 11

        fun start(ctx: Context) =
            ContextCompat.startForegroundService(ctx, Intent(ctx, CameraService::class.java).setAction(ACTION_START))

        fun send(ctx: Context, action: String, extras: (Intent) -> Unit = {}) {
            if (CameraEngine.running) ctx.startService(Intent(ctx, CameraService::class.java).setAction(action).also(extras))
        }
    }

    private lateinit var prefs: WatchmanPrefs
    private lateinit var events: EventStore
    private lateinit var clips: ClipStore
    private var server: WatchmanServer? = null
    private var nsd: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private val main = Handler(Looper.getMainLooper())
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val detector = MotionDetector()
    private val gate = MotionGate()
    private var provider: ProcessCameraProvider? = null
    private var recorderUse: VideoCapture<Recorder>? = null
    private var camera: Camera? = null
    private var activeRecording: Recording? = null
    private var lastMotionCheck = 0L
    private var lastFrame = 0L
    private var motionUntil = 0L
    private val stopClip = Runnable { activeRecording?.stop() }

    override fun onCreate() {
        super.onCreate()
        prefs = WatchmanPrefs(this)
        events = EventStore(this)
        clips = ClipStore(prefs, events)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        when (intent?.action) {
            ACTION_STOP -> shutdown()
            ACTION_SWITCH -> {
                prefs.facing = if (prefs.facing == "front") "back" else "front"
                bindCamera()
            }
            ACTION_REBIND -> bindCamera()
            ACTION_TORCH -> setTorch(intent.getBooleanExtra("on", false))
            ACTION_RECORD -> recordNow()
            else -> startWatching()
        }
        return START_NOT_STICKY
    }

    @SuppressLint("WakelockTimeout", "InlinedApi")
    private fun startWatching() {
        if (CameraEngine.running) return
        createChannel()
        try {
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            if (prefs.audio && hasMic()) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIF_ID, notification("Starting..."), types)
            else startForeground(NOTIF_ID, notification("Starting..."))
        } catch (e: Exception) {
            CameraEngine.error = "Could not start the camera service: ${e.message}"
            stopSelf()
            return
        }
        CameraEngine.reset()
        CameraEngine.running = true
        CameraEngine.facing = prefs.facing

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "watchman:watching").apply { acquire() }
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            else @Suppress("DEPRECATION") WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wm.createWifiLock(mode, "watchman:wifi").apply { acquire() }
        } catch (_: Exception) {}

        val srv = WatchmanServer(this, prefs, events)
        server = srv
        val port = try { srv.start() } catch (e: Exception) { 0 }
        CameraEngine.port = port
        if (port == 0) CameraEngine.error = "Could not open the network port."
        registerNsd(port)
        updateNotification()
        bindCamera()
    }

    private fun hasMic() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    // ---- camera ----

    private fun bindCamera() {
        val f = ProcessCameraProvider.getInstance(this)
        f.addListener({
            try {
                provider = f.get()
                bindUseCases()
            } catch (e: Exception) {
                CameraEngine.error = "Camera unavailable: ${e.message}"
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun bindUseCases() {
        val p = provider ?: return
        if (!CameraEngine.running) return
        activeRecording?.stop()
        p.unbindAll()
        detector.reset()
        gate.reset()
        val selector = if (prefs.facing == "front") CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA

        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setResolutionStrategy(ResolutionStrategy(Size(640, 480), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                    .build()
            )
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        analysis.setAnalyzer(analysisExecutor) { image -> analyze(image) }

        val recorder = Recorder.Builder()
            .setQualitySelector(QualitySelector.from(Quality.SD, FallbackStrategy.lowerQualityOrHigherThan(Quality.SD)))
            .build()
        val video = VideoCapture.withOutput(recorder)
        camera = null
        try {
            camera = p.bindToLifecycle(this, selector, analysis, video)
            recorderUse = video
            CameraEngine.recordingAvailable = true
            CameraEngine.error = null
        } catch (first: Exception) {
            try {
                p.unbindAll()
                camera = p.bindToLifecycle(this, selector, analysis)
                recorderUse = null
                CameraEngine.recordingAvailable = false
                CameraEngine.error = null
            } catch (second: Exception) {
                CameraEngine.error = "Could not open the ${prefs.facing} camera: ${second.message}"
                return
            }
        }
        CameraEngine.facing = prefs.facing
        // A new binding starts with the light off. Keep it on across a rebind when this camera has one.
        CameraEngine.hasTorch = camera?.cameraInfo?.hasFlashUnit() == true
        if (CameraEngine.torch && CameraEngine.hasTorch) setTorch(true) else CameraEngine.torch = false
        updateNotification()
    }

    private fun setTorch(on: Boolean) {
        val cam = camera
        if (cam == null || !CameraEngine.hasTorch) {
            CameraEngine.torch = false
            return
        }
        CameraEngine.torch = on
        try {
            cam.cameraControl.enableTorch(on)
        } catch (_: Exception) {
            CameraEngine.torch = false
        }
    }

    // ---- analysis (runs on analysisExecutor) ----

    private fun analyze(image: ImageProxy) {
        try {
            val now = SystemClock.elapsedRealtime()
            if (now - lastMotionCheck >= 250) {
                lastMotionCheck = now
                val plane = image.planes[0]
                val buf = plane.buffer
                buf.rewind()
                val bytes = ByteArray(buf.remaining())
                buf.get(bytes)
                val grid = downscaleLuma(bytes, image.width, image.height, plane.rowStride, plane.pixelStride)
                detector.sensitivity = prefs.sensitivity
                detector.minAreaPercent = prefs.minArea.toDouble()
                gate.cooldownMs = prefs.cooldownSec * 1000L
                val r = detector.analyze(grid)
                if (r.motion) {
                    CameraEngine.lastMotionMs = System.currentTimeMillis()
                    CameraEngine.motionNow = true
                    motionUntil = now + 3000
                    if (gate.shouldTrigger(true, CameraEngine.recording, now)) {
                        val score = r.changedFraction
                        main.post { onMotion(score) }
                    }
                } else if (now > motionUntil) {
                    CameraEngine.motionNow = false
                }
            }
            if (CameraEngine.wantsFrames && now - lastFrame >= 120) {
                lastFrame = now
                encode(image)
            }
        } catch (_: Exception) {
        } finally {
            image.close()
        }
    }

    private fun encode(image: ImageProxy) {
        val src = image.toBitmap()
        val m = Matrix()
        m.postRotate(image.imageInfo.rotationDegrees.toFloat())
        val bmp = Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
        val out = ByteArrayOutputStream(48 * 1024)
        bmp.compress(Bitmap.CompressFormat.JPEG, 65, out)
        if (bmp !== src) src.recycle()
        bmp.recycle()
        CameraEngine.publish(out.toByteArray())
    }

    // ---- clips (main thread) ----

    private fun onMotion(score: Double) {
        if (!CameraEngine.running) return
        val id = events.add(System.currentTimeMillis(), score)
        // Motion is always listed (and the viewer's Monitor still notifies); a clip only when Auto record is on.
        if (prefs.autoRecord) startClip(id)
    }

    /** A viewer asked for a clip now (app or web page). Logged as a manual event. */
    private fun recordNow() {
        if (!CameraEngine.running || recorderUse == null || activeRecording != null) {
            CameraEngine.recording = activeRecording != null
            return
        }
        startClip(events.add(System.currentTimeMillis(), 0.0, manual = true))
    }

    @SuppressLint("MissingPermission")
    private fun startClip(id: Long) {
        val video = recorderUse ?: run { CameraEngine.recording = false; return }
        if (activeRecording != null) return
        val name = "clip_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + ".mp4"
        val file = File(prefs.clipsDir(), name)
        try {
            var pending = video.output.prepareRecording(this, FileOutputOptions.Builder(file).build())
            if (prefs.audio && hasMic()) pending = pending.withAudioEnabled()
            CameraEngine.recording = true
            activeRecording = pending.start(ContextCompat.getMainExecutor(this)) { ev ->
                if (ev is VideoRecordEvent.Finalize) onFinalize(ev, file, id)
            }
            main.postDelayed(stopClip, prefs.clipSec * 1000L)
        } catch (e: Exception) {
            CameraEngine.recording = false
            activeRecording = null
            file.delete()
        }
    }

    private fun onFinalize(ev: VideoRecordEvent.Finalize, file: File, eventId: Long) {
        main.removeCallbacks(stopClip)
        activeRecording = null
        CameraEngine.recording = false
        if (!ev.hasError() && file.length() > 0) {
            events.attachClip(eventId, file.name)
            clips.enforceLimit()
        } else {
            file.delete()
        }
    }

    // ---- network ----

    private fun registerNsd(port: Int) {
        if (port == 0) return
        try {
            val mgr = getSystemService(Context.NSD_SERVICE) as NsdManager
            val info = NsdServiceInfo().apply {
                serviceName = "Watchman-" + prefs.cameraName
                serviceType = "_watchman._tcp."
                setPort(port)
            }
            val l = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(i: NsdServiceInfo) {}
                override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) {}
                override fun onServiceUnregistered(i: NsdServiceInfo) {}
                override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) {}
            }
            mgr.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
            nsd = mgr
            nsdListener = l
        } catch (_: Exception) {}
    }

    // ---- lifecycle ----

    private fun shutdown() {
        if (!CameraEngine.running) {
            stopSelf()
            return
        }
        CameraEngine.running = false
        activeRecording?.stop()
        try { nsdListener?.let { nsd?.unregisterService(it) } } catch (_: Exception) {}
        nsdListener = null
        server?.stop()
        server = null
        CameraEngine.wakeAll()
        // Give the recorder a moment to finish the file before the camera is released.
        main.postDelayed({
            try { provider?.unbindAll() } catch (_: Exception) {}
            releaseLocks()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }, 800)
    }

    private fun releaseLocks() {
        try { wakeLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        try { wifiLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        wakeLock = null
        wifiLock = null
    }

    override fun onDestroy() {
        if (CameraEngine.running) {
            CameraEngine.running = false
            try { nsdListener?.let { nsd?.unregisterService(it) } } catch (_: Exception) {}
            server?.stop()
            try { provider?.unbindAll() } catch (_: Exception) {}
        }
        releaseLocks()
        analysisExecutor.shutdown()
        super.onDestroy()
    }

    // ---- notification ----

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Watching", NotificationManager.IMPORTANCE_LOW))
    }

    private fun updateNotification() {
        val ip = CameraEngine.addresses().firstOrNull()
        val text = if (ip != null && CameraEngine.port != 0) "Watching on $ip:${CameraEngine.port}" else "Watching"
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, notification(text))
    }

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, CameraService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_watch)
            .setContentTitle("Watchman camera")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .build()
    }
}
