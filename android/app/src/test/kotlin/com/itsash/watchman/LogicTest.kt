package com.itsash.watchman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MotionDetectorTest {
    private fun flat(v: Int) = ByteArray(GRID_W * GRID_H) { v.toByte() }

    private fun withBlock(base: Int, value: Int, cells: Int): ByteArray {
        val g = flat(base)
        for (i in 0 until cells) g[i] = value.toByte()
        return g
    }

    @Test fun staticSceneIsNotMotion() {
        val d = MotionDetector(sensitivity = 60, minAreaPercent = 2.0)
        repeat(6) { assertFalse(d.analyze(flat(100)).motion) }
    }

    @Test fun firstFramesWarmUp() {
        val d = MotionDetector()
        assertFalse(d.analyze(flat(0)).motion)
        assertFalse(d.analyze(flat(255)).motion)
        assertTrue(d.analyze(flat(0)).motion) // third frame is the first one compared
    }

    @Test fun bigChangeIsMotion() {
        val d = MotionDetector(minAreaPercent = 2.0)
        repeat(3) { d.analyze(flat(100)) }
        val r = d.analyze(withBlock(100, 220, 600)) // ~19.5% of 3072
        assertTrue(r.motion)
        assertEquals(600.0 / 3072, r.changedFraction, 1e-9)
    }

    @Test fun smallChangeIsIgnored() {
        val d = MotionDetector(minAreaPercent = 5.0)
        repeat(3) { d.analyze(flat(100)) }
        assertFalse(d.analyze(withBlock(100, 220, 40)).motion) // 1.3% < 5%
    }

    @Test fun sensitivityChangesThreshold() {
        assertTrue(MotionDetector.pixelThresholdFor(100) < MotionDetector.pixelThresholdFor(1))
        assertEquals(8, MotionDetector.pixelThresholdFor(100))
        assertEquals(58, MotionDetector.pixelThresholdFor(1))
        // A 30-step brightness change is motion at high sensitivity, not at low.
        val hi = MotionDetector(sensitivity = 100, minAreaPercent = 2.0)
        val lo = MotionDetector(sensitivity = 1, minAreaPercent = 2.0)
        repeat(3) { hi.analyze(flat(100)); lo.analyze(flat(100)) }
        assertTrue(hi.analyze(flat(130)).motion)
        assertFalse(lo.analyze(flat(130)).motion)
    }

    @Test fun resetRestartsWarmUp() {
        val d = MotionDetector()
        repeat(3) { d.analyze(flat(100)) }
        d.reset()
        assertFalse(d.analyze(flat(250)).motion)
    }

    @Test fun downscaleHonoursStride() {
        // 8x4 image with rowStride 10 (2 padding bytes per row); left half 10, right half 200.
        val w = 8; val h = 4; val stride = 10
        val data = ByteArray(stride * h)
        for (y in 0 until h) for (x in 0 until w) data[y * stride + x] = (if (x < 4) 10 else 200).toByte()
        val g = downscaleLuma(data, w, h, stride, 1, gridW = 2, gridH = 2)
        assertEquals(10, g[0].toInt() and 0xFF)
        assertEquals(200 , g[1].toInt() and 0xFF)
        assertEquals(10, g[2].toInt() and 0xFF)
        assertEquals(200, g[3].toInt() and 0xFF)
    }
}

class MotionGateTest {
    @Test fun cooldownBlocksRepeatTriggers() {
        val g = MotionGate(cooldownMs = 10_000)
        assertTrue(g.shouldTrigger(true, false, 1_000))
        assertFalse(g.shouldTrigger(true, false, 5_000))
        assertTrue(g.shouldTrigger(true, false, 11_001))
    }

    @Test fun noTriggerWithoutMotionOrWhileRecording() {
        val g = MotionGate(cooldownMs = 0)
        assertFalse(g.shouldTrigger(false, false, 1))
        assertFalse(g.shouldTrigger(true, true, 2))
        assertTrue(g.shouldTrigger(true, false, 3))
    }
}

class PinGuardTest {
    @Test fun correctPinPasses() {
        val g = PinGuard()
        assertTrue(g.check("1.1.1.1", "123456", "123456", 0))
    }

    @Test fun wrongOrMissingPinFails() {
        val g = PinGuard()
        assertFalse(g.check("1.1.1.1", "000000", "123456", 0))
        assertFalse(g.check("1.1.1.1", null, "123456", 0))
        assertFalse(g.check("1.1.1.1", "12345", "123456", 0))
    }

    @Test fun locksAfterFiveWrongTriesThenRecovers() {
        val g = PinGuard(maxFailures = 5, lockMs = 60_000)
        repeat(5) { assertFalse(g.check("a", "0000", "1234", it.toLong())) }
        assertTrue(g.isLocked("a", 100))
        assertFalse(g.check("a", "1234", "1234", 1_000)) // correct, but locked
        assertTrue(g.check("a", "1234", "1234", 61_000))
        assertFalse(g.isLocked("a", 61_001))
    }

    @Test fun lockoutIsPerClient() {
        val g = PinGuard(maxFailures = 2, lockMs = 60_000)
        repeat(2) { g.check("a", "x", "1234", 0) }
        assertTrue(g.check("b", "1234", "1234", 1))
    }

    @Test fun missingPinDoesNotCountAsGuess() {
        val g = PinGuard(maxFailures = 2, lockMs = 60_000)
        repeat(10) { g.check("a", null, "1234", 0) }
        assertTrue(g.check("a", "1234", "1234", 1))
    }

    @Test fun pinFormat() {
        assertTrue(PinGuard.isValidPin("1234"))
        assertTrue(PinGuard.isValidPin("123456"))
        assertFalse(PinGuard.isValidPin("123"))
        assertFalse(PinGuard.isValidPin("1234567"))
        assertFalse(PinGuard.isValidPin("12a4"))
        assertFalse(PinGuard.isValidPin(null))
        val p = PinGuard.generate()
        assertEquals(6, p.length)
        assertTrue(PinGuard.isValidPin(p))
    }
}

class StoragePolicyTest {
    private fun clip(n: Int, size: Long) = StoredClip("c$n.mp4", size, n.toLong())

    @Test fun unlimitedDeletesNothing() {
        assertTrue(StoragePolicy.toDelete(listOf(clip(1, 100), clip(2, 100)), 0).isEmpty())
    }

    @Test fun underLimitDeletesNothing() {
        assertTrue(StoragePolicy.toDelete(listOf(clip(1, 100), clip(2, 100)), 500).isEmpty())
    }

    @Test fun deletesOldestFirstUntilFits() {
        val clips = listOf(clip(3, 100), clip(1, 100), clip(2, 100), clip(4, 100))
        val del = StoragePolicy.toDelete(clips, 250)
        assertEquals(listOf("c1.mp4", "c2.mp4"), del.map { it.name })
    }

    @Test fun newestClipIsAlwaysKept() {
        val del = StoragePolicy.toDelete(listOf(clip(1, 1000), clip(2, 1000)), 10)
        assertEquals(listOf("c1.mp4"), del.map { it.name })
    }

    @Test fun safeClipNames() {
        assertTrue(StoragePolicy.isSafeClipName("clip_20260101_101010.mp4"))
        assertFalse(StoragePolicy.isSafeClipName("../secret.mp4"))
        assertFalse(StoragePolicy.isSafeClipName("a/b.mp4"))
        assertFalse(StoragePolicy.isSafeClipName("clip.txt"))
        assertFalse(StoragePolicy.isSafeClipName(""))
    }
}
