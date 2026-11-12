package com.itsash.watchman

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Motion events of this camera, kept in events.json (newest 200). */
class EventStore(context: Context) {
    private val file = File(context.applicationContext.filesDir, "events.json")
    private val items = ArrayList<JSONObject>()
    private var nextId = 1L

    init {
        try {
            if (file.exists()) {
                val arr = JSONArray(file.readText())
                for (i in 0 until arr.length()) items.add(arr.getJSONObject(i))
                nextId = (items.maxOfOrNull { it.optLong("id") } ?: 0L) + 1
            }
        } catch (_: Exception) {
            items.clear()
        }
    }

    @Synchronized
    fun add(tsMs: Long, score: Double): Long {
        val id = nextId++
        items.add(JSONObject().put("id", id).put("ts", tsMs).put("score", Math.round(score * 1000) / 10.0))
        while (items.size > 200) items.removeAt(0)
        save()
        return id
    }

    @Synchronized
    fun attachClip(id: Long, clip: String) {
        items.firstOrNull { it.optLong("id") == id }?.put("clip", clip)
        save()
    }

    @Synchronized
    fun removeClip(clip: String) {
        var changed = false
        for (e in items) if (e.optString("clip") == clip) { e.remove("clip"); changed = true }
        if (changed) save()
    }

    /** Events with id greater than [since], oldest first. */
    @Synchronized
    fun since(since: Long): JSONArray {
        val out = JSONArray()
        items.filter { it.optLong("id") > since }.forEach { out.put(it) }
        return out
    }

    @Synchronized
    fun clear() {
        items.clear()
        save()
    }

    private fun save() {
        try { file.writeText(JSONArray(items).toString()) } catch (_: Exception) {}
    }
}
