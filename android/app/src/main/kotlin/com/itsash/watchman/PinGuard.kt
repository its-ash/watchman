package com.itsash.watchman

import java.security.MessageDigest
import java.security.SecureRandom

/** PIN generation and checking, with a lockout after repeated wrong tries. Pure, no Android types. */
class PinGuard(
    private val maxFailures: Int = 5,
    private val lockMs: Long = 60_000,
) {
    private class Entry(var failures: Int = 0, var lockedUntil: Long = 0)

    private val entries = HashMap<String, Entry>()

    /** Returns true if [given] equals [pin]. [client] (an IP address) is locked out after too many misses. */
    @Synchronized
    fun check(client: String, given: String?, pin: String, nowMs: Long): Boolean {
        val e = entries.getOrPut(client) { Entry() }
        if (nowMs < e.lockedUntil) return false
        if (given != null && constantTimeEquals(given, pin)) {
            e.failures = 0
            return true
        }
        // A request with no PIN at all is not a guess; only wrong PINs count.
        if (given != null) {
            e.failures++
            if (e.failures >= maxFailures) {
                e.failures = 0
                e.lockedUntil = nowMs + lockMs
            }
        }
        return false
    }

    @Synchronized
    fun isLocked(client: String, nowMs: Long): Boolean = (entries[client]?.lockedUntil ?: 0) > nowMs

    companion object {
        fun isValidPin(pin: String?): Boolean = pin != null && pin.length in 4..6 && pin.all { it in '0'..'9' }

        fun generate(random: SecureRandom = SecureRandom(), length: Int = 6): String =
            buildString { repeat(length) { append(random.nextInt(10)) } }

        fun constantTimeEquals(a: String, b: String): Boolean =
            MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))
    }
}
