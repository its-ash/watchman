package com.itsash.watchman

import kotlin.math.abs

/** Pure motion logic: no Android types, so it runs in JVM unit tests. */

const val GRID_W = 64
const val GRID_H = 48

/**
 * Downscales one image plane (8-bit luma) to a GRID_W x GRID_H grayscale grid by sampling the centre of
 * each cell. [rowStride] and [pixelStride] come from the camera plane, so padding bytes are skipped.
 */
fun downscaleLuma(
    luma: ByteArray, width: Int, height: Int, rowStride: Int, pixelStride: Int = 1,
    gridW: Int = GRID_W, gridH: Int = GRID_H,
): ByteArray {
    val out = ByteArray(gridW * gridH)
    if (width <= 0 || height <= 0) return out
    for (gy in 0 until gridH) {
        val y = ((gy + 0.5) * height / gridH).toInt().coerceIn(0, height - 1)
        for (gx in 0 until gridW) {
            val x = ((gx + 0.5) * width / gridW).toInt().coerceIn(0, width - 1)
            val i = y * rowStride + x * pixelStride
            out[gy * gridW + gx] = if (i < luma.size) luma[i] else 0
        }
    }
    return out
}

data class MotionResult(val changedFraction: Double, val motion: Boolean)

/**
 * Compares each grid to the previous one. A cell counts as changed when its brightness moved by more than
 * a threshold that shrinks as [sensitivity] (1..100) grows. Motion is reported when the changed share of
 * the picture reaches [minAreaPercent]; smaller changes (noise, a flickering pixel) are ignored.
 */
class MotionDetector(
    var sensitivity: Int = 60,
    var minAreaPercent: Double = 2.0,
    private val warmupFrames: Int = 2,
) {
    private var previous: ByteArray? = null
    private var seen = 0

    fun reset() {
        previous = null
        seen = 0
    }

    /** Brightness step (0..255) that counts as a change for the current sensitivity. */
    fun pixelThreshold(): Int = pixelThresholdFor(sensitivity)

    fun analyze(grid: ByteArray): MotionResult {
        val prev = previous
        previous = grid
        seen++
        if (prev == null || prev.size != grid.size || grid.isEmpty() || seen <= warmupFrames) {
            return MotionResult(0.0, false)
        }
        val threshold = pixelThreshold()
        var changed = 0
        for (i in grid.indices) {
            if (abs((grid[i].toInt() and 0xFF) - (prev[i].toInt() and 0xFF)) > threshold) changed++
        }
        val fraction = changed.toDouble() / grid.size
        return MotionResult(fraction, fraction * 100.0 >= minAreaPercent)
    }

    companion object {
        /** sensitivity 100 -> 8, sensitivity 1 -> 58. */
        fun pixelThresholdFor(sensitivity: Int): Int = 58 - (sensitivity.coerceIn(1, 100) - 1) * 50 / 99
    }
}

/**
 * Decides when a motion reading starts a clip: not while one is recording, and not before [cooldownMs]
 * has passed since the last clip started.
 */
class MotionGate(var cooldownMs: Long = 10_000) {
    private var lastTriggerMs = Long.MIN_VALUE / 2

    fun shouldTrigger(motion: Boolean, recording: Boolean, nowMs: Long): Boolean {
        if (!motion || recording) return false
        if (nowMs - lastTriggerMs < cooldownMs) return false
        lastTriggerMs = nowMs
        return true
    }

    fun reset() {
        lastTriggerMs = Long.MIN_VALUE / 2
    }
}
