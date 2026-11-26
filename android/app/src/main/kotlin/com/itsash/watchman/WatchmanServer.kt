package com.itsash.watchman

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.concurrent.Executors

/**
 * Tiny HTTP/1.1 server for the LAN, used by the Watchman viewer app and by any browser.
 *
 * Open routes:
 *   GET  /                web page (PIN login, live view, controls, events and clips)
 *   GET  /hello           {"app":"watchman","name":...}
 *   POST /login           {"pin":"..."} -> session cookie for the web page;  POST /logout
 * Everything else needs the PIN (header X-Pin or ?pin=) or a valid session cookie:
 *   GET  /status          JSON status (state + motion settings)
 *   GET  /snapshot.jpg    one JPEG
 *   GET  /stream          MJPEG, multipart/x-mixed-replace
 *   GET  /events?since=N  motion events with id > N
 *   GET  /clips           clip list;  /clips/<name>.mp4  the clip (Range supported)
 *   POST /control/switch | /control/torch {on} | /control/record | /control/settings {autoRecord: bool, key: int}
 *        | /control/delete-clip {name}   -> {"ok":true,"status":{...}} or {"error":"..."}
 * Every POST must be Content-Type application/json: a plain cross-site form cannot send that, and the
 * session cookie is SameSite=Strict, so other web pages cannot drive the camera.
 */
class WatchmanServer(
    private val ctx: Context,
    private val prefs: WatchmanPrefs,
    private val events: EventStore,
    private val guard: PinGuard = PinGuard(),
) {
    private var server: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool { r -> Thread(r, "watchman-http").apply { isDaemon = true } }
    private val sessions = WebSessions()
    private val clips = ClipStore(prefs, events)
    private val page: ByteArray? by lazy {
        try { ctx.assets.open("web/index.html").use { it.readBytes() } } catch (_: Exception) { null }
    }

    /** Binds the preferred port, or any free port when it is taken. Returns the port. */
    fun start(): Int {
        val s = ServerSocket()
        try {
            s.reuseAddress = true
            try {
                s.bind(InetSocketAddress(prefs.port))
            } catch (_: Exception) {
                s.bind(InetSocketAddress(0))
            }
        } catch (e: Exception) {
            try { s.close() } catch (_: Exception) {}
            throw e
        }
        server = s
        pool.execute {
            while (!s.isClosed) {
                try {
                    val c = s.accept()
                    pool.execute { handle(c) }
                } catch (_: Exception) {
                    break
                }
            }
        }
        return s.localPort
    }

    fun stop() {
        try { server?.close() } catch (_: Exception) {}
        CameraEngine.wakeAll()
        pool.shutdownNow()
    }

    private class Request(
        val method: String,
        val path: String,
        val query: Map<String, String>,
        val headers: Map<String, String>,
        val body: String,
    )

    private fun readRequest(input: BufferedInputStream): Request? {
        val sb = StringBuilder()
        var last4 = 0
        while (sb.length < 8192) {
            val b = input.read()
            if (b < 0) return null
            sb.append(b.toChar())
            last4 = (last4 shl 8) or b
            if (last4 == 0x0D0A0D0A) break
        }
        val lines = sb.toString().split("\r\n")
        val parts = lines.firstOrNull()?.split(" ") ?: return null
        if (parts.size < 2 || (parts[0] != "GET" && parts[0] != "POST")) return null
        val target = parts[1]
        val path = target.substringBefore('?')
        val query = HashMap<String, String>()
        if (target.contains('?')) {
            for (kv in target.substringAfter('?').split('&')) {
                val k = kv.substringBefore('=')
                val v = if (kv.contains('=')) kv.substringAfter('=') else ""
                if (k.isNotEmpty()) query[URLDecoder.decode(k, "UTF-8")] = URLDecoder.decode(v, "UTF-8")
            }
        }
        val headers = HashMap<String, String>()
        for (l in lines.drop(1)) {
            val i = l.indexOf(':')
            if (i > 0) headers[l.substring(0, i).trim().lowercase()] = l.substring(i + 1).trim()
        }
        var body = ""
        if (parts[0] == "POST") {
            val len = headers["content-length"]?.toIntOrNull() ?: 0
            if (len < 0 || len > MAX_BODY) return null
            val buf = ByteArray(len)
            var got = 0
            while (got < len) {
                val n = input.read(buf, got, len - got)
                if (n < 0) return null
                got += n
            }
            body = String(buf, Charsets.UTF_8)
        }
        return Request(parts[0], path, query, headers, body)
    }

    private fun handle(socket: Socket) {
        try {
            socket.soTimeout = 15_000
            socket.tcpNoDelay = true
            val input = BufferedInputStream(socket.getInputStream())
            val out = socket.getOutputStream()
            val req = readRequest(input)
            if (req == null) {
                respond(out, 400, "application/json", """{"error":"bad request"}""".toByteArray())
                return
            }
            route(req, socket, out)
        } catch (_: Exception) {
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun route(req: Request, socket: Socket, out: OutputStream) {
        val get = req.method == "GET"
        if (get && (req.path == "/" || req.path == "/index.html")) {
            val html = page
            if (html == null) respond(out, 404, "application/json", """{"error":"no page"}""".toByteArray())
            else respond(out, 200, "text/html; charset=utf-8", html, PAGE_HEADERS)
            return
        }
        if (get && req.path == "/hello") {
            val j = JSONObject().put("app", "watchman").put("name", prefs.cameraName).put("auth", "pin")
            respond(out, 200, "application/json", j.toString().toByteArray())
            return
        }
        if (!get && req.headers["content-type"]?.startsWith("application/json") != true) {
            json(out, 415, JSONObject().put("error", "Send JSON."))
            return
        }
        val client = (socket.inetAddress as? InetAddress)?.hostAddress ?: "?"
        val now = System.currentTimeMillis()
        if (req.path == "/login") {
            login(req, client, now, out)
            return
        }
        if (req.path == "/logout") {
            sessions.remove(WebSessions.cookie(req.headers["cookie"]))
            json(out, 200, JSONObject().put("ok", true), listOf("Set-Cookie: ${WebSessions.COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"))
            return
        }
        val given = req.headers["x-pin"] ?: req.query["pin"]
        val session = given == null && sessions.isValid(WebSessions.cookie(req.headers["cookie"]), prefs.pin, now)
        if (!session && !guard.check(client, given, prefs.pin, now)) {
            val locked = guard.isLocked(client, now)
            respond(out, if (locked) 429 else 401, "application/json",
                JSONObject().put("error", if (locked) "locked" else "pin").toString().toByteArray())
            return
        }
        if (!get) {
            control(req, out)
            return
        }
        when {
            req.path == "/status" ->
                respond(out, 200, "application/json", CameraEngine.statusJson(ctx, events).toString().toByteArray())
            req.path == "/events" -> {
                val since = req.query["since"]?.toLongOrNull() ?: 0L
                respond(out, 200, "application/json", events.since(since).toString().toByteArray())
            }
            req.path == "/clips" -> respond(out, 200, "application/json", clipList().toString().toByteArray())
            req.path.startsWith("/clips/") -> serveClip(req, out)
            req.path == "/snapshot.jpg" -> snapshot(out)
            req.path == "/stream" -> stream(out)
            else -> respond(out, 404, "application/json", """{"error":"not found"}""".toByteArray())
        }
    }

    private fun login(req: Request, client: String, now: Long, out: OutputStream) {
        val pin = try { JSONObject(req.body).optString("pin", "") } catch (_: Exception) { "" }
        if (!guard.check(client, pin, prefs.pin, now)) {
            val locked = guard.isLocked(client, now)
            json(out, if (locked) 429 else 401, JSONObject().put(
                "error", if (locked) "Too many wrong PINs. Try again in a minute." else "Wrong PIN."))
            return
        }
        val token = sessions.create(prefs.pin, now)
        json(
            out, 200, JSONObject().put("ok", true).put("name", prefs.cameraName),
            listOf("Set-Cookie: ${WebSessions.COOKIE}=$token; Path=/; Max-Age=604800; HttpOnly; SameSite=Strict"),
        )
    }

    /** Remote controls, shared by the web page and the viewer app. Runs only after the PIN check. */
    private fun control(req: Request, out: OutputStream) {
        val body = try {
            if (req.body.isBlank()) JSONObject() else JSONObject(req.body)
        } catch (_: Exception) {
            json(out, 400, JSONObject().put("error", "Bad JSON."))
            return
        }
        fun fail(code: Int, msg: String) = json(out, code, JSONObject().put("error", msg))
        if (!CameraEngine.running) return fail(409, "The camera is not running.")
        when (req.path) {
            "/control/switch" -> CameraService.send(ctx, CameraService.ACTION_SWITCH)
            "/control/torch" -> {
                if (!CameraEngine.hasTorch) return fail(409, "This camera has no light.")
                val on = body.optBoolean("on", !CameraEngine.torch)
                CameraEngine.torch = on
                CameraService.send(ctx, CameraService.ACTION_TORCH) { it.putExtra("on", on) }
            }
            "/control/record" -> {
                if (!CameraEngine.recordingAvailable) return fail(409, "This phone cannot record clips while it streams.")
                if (CameraEngine.recording) return fail(409, "Already recording.")
                CameraEngine.recording = true // shown at once; the service resets it if the clip cannot start
                CameraService.send(ctx, CameraService.ACTION_RECORD)
            }
            "/control/settings" -> {
                if (body.has("autoRecord")) {
                    val v = body.opt("autoRecord") as? Boolean ?: return fail(400, "autoRecord must be true or false.")
                    prefs.autoRecord = v
                }
                for (key in REMOTE_SETTINGS) {
                    if (!body.has(key)) continue
                    val v = body.opt(key) as? Number ?: return fail(400, "$key must be a number.")
                    prefs.set(key, v.toInt())
                }
            }
            "/control/delete-clip" -> {
                val name = body.optString("name", "")
                if (!StoragePolicy.isSafeClipName(name)) return fail(400, "Bad clip name.")
                if (!clips.delete(name)) return fail(404, "Clip not found.")
            }
            else -> return fail(404, "Unknown control.")
        }
        json(out, 200, JSONObject().put("ok", true).put("status", CameraEngine.statusJson(ctx, events)))
    }

    private fun clipList(): JSONArray {
        val arr = JSONArray()
        prefs.clipsDir().listFiles { f -> f.isFile && f.name.endsWith(".mp4") }
            ?.sortedBy { it.lastModified() }
            ?.forEach { arr.put(JSONObject().put("name", it.name).put("size", it.length()).put("ts", it.lastModified())) }
        return arr
    }

    private fun snapshot(out: OutputStream) {
        CameraEngine.viewers.incrementAndGet()
        try {
            val frame = CameraEngine.waitFrame(CameraEngine.currentSeq(), 3000) ?: CameraEngine.waitFrame(-1, 10)
            if (frame == null) respond(out, 503, "application/json", """{"error":"no frame"}""".toByteArray())
            else respond(out, 200, "image/jpeg", frame.first)
        } finally {
            CameraEngine.viewers.decrementAndGet()
        }
    }

    private fun stream(out: OutputStream) {
        CameraEngine.viewers.incrementAndGet()
        try {
            out.write(
                ("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n" +
                    "Cache-Control: no-cache, no-store\r\nConnection: close\r\n\r\n").toByteArray()
            )
            out.flush()
            var seq = -1L
            var idle = 0
            while (CameraEngine.running) {
                val f = CameraEngine.waitFrame(seq, 1000)
                if (f == null) {
                    // Keep the connection checked: a failed write ends the loop.
                    if (++idle > 30) break
                    continue
                }
                idle = 0
                seq = f.second
                out.write("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${f.first.size}\r\n\r\n".toByteArray())
                out.write(f.first)
                out.write("\r\n".toByteArray())
                out.flush()
            }
        } finally {
            CameraEngine.viewers.decrementAndGet()
        }
    }

    private fun serveClip(req: Request, out: OutputStream) {
        val name = req.path.removePrefix("/clips/")
        if (!StoragePolicy.isSafeClipName(name)) {
            respond(out, 400, "application/json", """{"error":"bad name"}""".toByteArray())
            return
        }
        val file = File(prefs.clipsDir(), name)
        if (!file.isFile) {
            respond(out, 404, "application/json", """{"error":"not found"}""".toByteArray())
            return
        }
        val total = file.length()
        var start = 0L
        var end = total - 1
        var partial = false
        val range = req.headers["range"]
        if (range != null && range.startsWith("bytes=")) {
            val spec = range.removePrefix("bytes=").substringBefore(',')
            val a = spec.substringBefore('-')
            val b = spec.substringAfter('-', "")
            if (a.isEmpty()) {
                val n = b.toLongOrNull() ?: 0L
                start = (total - n).coerceAtLeast(0)
            } else {
                start = a.toLongOrNull() ?: 0L
                if (b.isNotEmpty()) end = (b.toLongOrNull() ?: end).coerceAtMost(total - 1)
            }
            partial = true
            if (start > end || start >= total) {
                out.write("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */$total\r\nConnection: close\r\n\r\n".toByteArray())
                return
            }
        }
        val length = end - start + 1
        val head = StringBuilder()
            .append(if (partial) "HTTP/1.1 206 Partial Content\r\n" else "HTTP/1.1 200 OK\r\n")
            .append("Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: $length\r\n")
        if (partial) head.append("Content-Range: bytes $start-$end/$total\r\n")
        head.append("Connection: close\r\n\r\n")
        out.write(head.toString().toByteArray())
        RandomAccessFile(file, "r").use { raf ->
            raf.seek(start)
            val buf = ByteArray(64 * 1024)
            var left = length
            while (left > 0) {
                val n = raf.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                if (n < 0) break
                out.write(buf, 0, n)
                left -= n
            }
        }
        out.flush()
    }

    private fun json(out: OutputStream, code: Int, j: JSONObject, extra: List<String> = emptyList()) =
        respond(out, code, "application/json", j.toString().toByteArray(), extra)

    private fun respond(out: OutputStream, code: Int, type: String, body: ByteArray, extra: List<String> = emptyList()) {
        val reason = when (code) {
            200 -> "OK"; 400 -> "Bad Request"; 401 -> "Unauthorized"; 404 -> "Not Found"; 409 -> "Conflict"
            415 -> "Unsupported Media Type"; 429 -> "Too Many Requests"; 503 -> "Service Unavailable"; else -> "Error"
        }
        val head = StringBuilder("HTTP/1.1 $code $reason\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\n")
        head.append("Cache-Control: no-store\r\n")
        for (h in extra) head.append(h).append("\r\n")
        head.append("Connection: close\r\n\r\n")
        out.write(head.toString().toByteArray())
        out.write(body)
        out.flush()
    }

    companion object {
        private const val MAX_BODY = 16 * 1024

        /** Motion settings a viewer may change from the app or the web page. */
        val REMOTE_SETTINGS = listOf("sensitivity", "minArea", "cooldownSec", "clipSec")

        private val PAGE_HEADERS = listOf(
            "Content-Security-Policy: default-src 'self'; img-src 'self' data: blob:; media-src 'self'; " +
                "style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'",
            "X-Frame-Options: DENY",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer",
        )
    }
}
