package com.itsash.watchman

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.concurrent.Executors

/**
 * Tiny HTTP/1.1 server for the LAN. Routes (all but /hello need the PIN as header X-Pin or ?pin=):
 *   /hello            no PIN; {"app":"watchman","name":...}
 *   /status           JSON status
 *   /snapshot.jpg     one JPEG
 *   /stream           MJPEG, multipart/x-mixed-replace
 *   /events?since=N   motion events with id > N
 *   /clips            clip list;  /clips/<name>.mp4  the clip (Range supported)
 */
class WatchmanServer(
    private val ctx: Context,
    private val prefs: WatchmanPrefs,
    private val events: EventStore,
    private val guard: PinGuard = PinGuard(),
) {
    private var server: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool { r -> Thread(r, "watchman-http").apply { isDaemon = true } }

    /** Binds the preferred port, or any free port when it is taken. Returns the port. */
    fun start(): Int {
        val s = try { ServerSocket(prefs.port) } catch (_: Exception) { ServerSocket(0) }
        s.reuseAddress = true
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

    private class Request(val path: String, val query: Map<String, String>, val headers: Map<String, String>)

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
        if (parts.size < 2 || parts[0] != "GET") return null
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
        return Request(path, query, headers)
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
        if (req.path == "/hello") {
            val j = JSONObject().put("app", "watchman").put("name", prefs.cameraName).put("auth", "pin")
            respond(out, 200, "application/json", j.toString().toByteArray())
            return
        }
        val client = (socket.inetAddress as? InetAddress)?.hostAddress ?: "?"
        val now = System.currentTimeMillis()
        val given = req.headers["x-pin"] ?: req.query["pin"]
        if (!guard.check(client, given, prefs.pin, now)) {
            val locked = guard.isLocked(client, now)
            respond(out, if (locked) 429 else 401, "application/json",
                JSONObject().put("error", if (locked) "locked" else "pin").toString().toByteArray())
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

    private fun respond(out: OutputStream, code: Int, type: String, body: ByteArray) {
        val reason = when (code) {
            200 -> "OK"; 400 -> "Bad Request"; 401 -> "Unauthorized"; 404 -> "Not Found"
            429 -> "Too Many Requests"; 503 -> "Service Unavailable"; else -> "Error"
        }
        out.write(
            ("HTTP/1.1 $code $reason\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\n" +
                "Cache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray()
        )
        out.write(body)
        out.flush()
    }
}
