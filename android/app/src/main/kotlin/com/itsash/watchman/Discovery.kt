package com.itsash.watchman

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper

/** Finds cameras advertising _watchman._tcp with NSD. Calls [onChange] on the main thread. */
class Discovery(context: Context, private val onChange: (List<Map<String, Any>>) -> Unit) {
    private val ctx = context.applicationContext
    private val nsd = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private val found = LinkedHashMap<String, Map<String, Any>>()
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null
    @Volatile private var lock: WifiManager.MulticastLock? = null

    fun start() {
        if (listener != null) return
        try {
            val wm = ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager
            lock = wm.createMulticastLock("watchman:discovery").apply { setReferenceCounted(false); acquire() }
        } catch (_: Exception) {}
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(t: String) {}
            override fun onStartDiscoveryFailed(t: String, code: Int) {
                listener = null
                releaseLock()
            }
            override fun onStopDiscoveryFailed(t: String, code: Int) {}
            override fun onDiscoveryStopped(t: String) {}
            override fun onServiceFound(s: NsdServiceInfo) {
                main.post { queue.add(s); next() }
            }
            override fun onServiceLost(s: NsdServiceInfo) {
                main.post {
                    found.remove(s.serviceName)
                    emit()
                }
            }
        }
        listener = l
        try {
            nsd.discoverServices("_watchman._tcp.", NsdManager.PROTOCOL_DNS_SD, l)
        } catch (_: Exception) {
            listener = null
            releaseLock()
        }
    }

    fun stop() {
        listener?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) {} }
        listener = null
        releaseLock()
        queue.clear()
        found.clear()
        resolving = false
    }

    private fun releaseLock() {
        val l = lock
        lock = null
        try { l?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
    }

    @Suppress("DEPRECATION")
    private fun next() {
        if (resolving || queue.isEmpty()) return
        val s = queue.removeFirst()
        resolving = true
        try {
            nsd.resolveService(s, object : NsdManager.ResolveListener {
                override fun onResolveFailed(i: NsdServiceInfo, code: Int) {
                    main.post { resolving = false; next() }
                }

                override fun onServiceResolved(i: NsdServiceInfo) {
                    main.post {
                        val host = i.host?.hostAddress
                        if (host != null) {
                            found[i.serviceName] = mapOf(
                                "name" to i.serviceName.removePrefix("Watchman-"), "host" to host, "port" to i.port,
                            )
                            emit()
                        }
                        resolving = false
                        next()
                    }
                }
            })
        } catch (_: Exception) {
            resolving = false
        }
    }

    private fun emit() = onChange(found.values.toList())
}
