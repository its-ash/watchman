package com.itsash.watchman

import java.security.SecureRandom

/**
 * Browser sessions for the web page. After a correct PIN the browser gets a random token in a cookie, so
 * the PIN never sits in URLs or history. A token is only good for the PIN it was issued under: changing
 * the PIN logs every browser out. Pure, no Android types.
 */
class WebSessions(
    private val ttlMs: Long = 7L * 24 * 3600 * 1000,
    private val max: Int = 32,
    private val random: SecureRandom = SecureRandom(),
) {
    private class Session(val pin: String, val expiresMs: Long)

    private val sessions = LinkedHashMap<String, Session>()

    @Synchronized
    fun create(pin: String, nowMs: Long): String {
        sessions.entries.removeAll { it.value.expiresMs <= nowMs }
        while (sessions.size >= max) sessions.remove(sessions.keys.first())
        val bytes = ByteArray(24).also { random.nextBytes(it) }
        val token = bytes.joinToString("") { "%02x".format(it) }
        sessions[token] = Session(pin, nowMs + ttlMs)
        return token
    }

    @Synchronized
    fun isValid(token: String?, pin: String, nowMs: Long): Boolean {
        if (token == null) return false
        val s = sessions[token] ?: return false
        if (nowMs >= s.expiresMs || !PinGuard.constantTimeEquals(s.pin, pin)) {
            sessions.remove(token)
            return false
        }
        return true
    }

    @Synchronized
    fun remove(token: String?) {
        if (token != null) sessions.remove(token)
    }

    companion object {
        const val COOKIE = "wm_session"

        /** Value of cookie [name] in a `Cookie:` header, or null. */
        fun cookie(header: String?, name: String = COOKIE): String? =
            header?.split(';')?.map { it.trim() }?.firstOrNull { it.startsWith("$name=") }?.substringAfter('=')
                ?.takeIf { it.isNotEmpty() }
    }
}
