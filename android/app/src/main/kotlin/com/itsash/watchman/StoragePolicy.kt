package com.itsash.watchman

data class StoredClip(val name: String, val sizeBytes: Long, val modifiedMs: Long)

/** Storage limit rule. Pure, so the oldest-first deletion is unit tested. */
object StoragePolicy {
    /**
     * Returns the clips to delete, oldest first, so the rest fit within [limitBytes].
     * A [limitBytes] of 0 or less means unlimited. The newest clip is always kept.
     */
    fun toDelete(clips: List<StoredClip>, limitBytes: Long): List<StoredClip> {
        if (limitBytes <= 0 || clips.size <= 1) return emptyList()
        var total = clips.sumOf { it.sizeBytes }
        val result = ArrayList<StoredClip>()
        val oldestFirst = clips.sortedBy { it.modifiedMs }
        for (clip in oldestFirst.dropLast(1)) {
            if (total <= limitBytes) break
            result.add(clip)
            total -= clip.sizeBytes
        }
        return result
    }

    /** A safe clip file name: letters, digits, dash, underscore, then ".mp4". Blocks path tricks. */
    fun isSafeClipName(name: String): Boolean = Regex("[A-Za-z0-9_-]{1,64}\\.mp4").matches(name)
}
