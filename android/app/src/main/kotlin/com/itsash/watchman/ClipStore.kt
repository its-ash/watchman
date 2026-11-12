package com.itsash.watchman

import java.io.File

/** Clip files on this phone: listing, deleting and the storage limit. */
class ClipStore(private val prefs: WatchmanPrefs, private val events: EventStore) {
    private fun files(): List<File> =
        prefs.clipsDir().listFiles { f -> f.isFile && f.name.endsWith(".mp4") }?.toList() ?: emptyList()

    fun list(): List<StoredClip> =
        files().map { StoredClip(it.name, it.length(), it.lastModified()) }.sortedByDescending { it.modifiedMs }

    fun delete(name: String): Boolean {
        if (!StoragePolicy.isSafeClipName(name)) return false
        val ok = File(prefs.clipsDir(), name).delete()
        events.removeClip(name)
        return ok
    }

    fun deleteAll() {
        files().forEach { delete(it.name) }
    }

    /** Deletes the oldest clips until the total is within the storage limit. */
    fun enforceLimit() {
        val limit = prefs.storageMb.toLong() * 1024 * 1024
        StoragePolicy.toDelete(list(), limit).forEach { delete(it.name) }
    }
}
