package com.bling.wakeguard

import org.junit.Assert.*
import org.junit.Test

class ObjectRecognitionProgressTest {
    @Test fun sinkRequiresAConfidentStartAndCanMaintainASlightlyWeakerMatch() {
        assertFalse(matchesObjectLabel("sink", 7, 0.65f, false))
        assertTrue(matchesObjectLabel("sink", 7, 0.70f, false))
        assertTrue(matchesObjectLabel("sink", 7, 0.60f, true))
        assertFalse(matchesObjectLabel("sink", 7, 0.59f, true))
        assertFalse(matchesObjectLabel("sink", 315, 0.99f, true))
        assertFalse(matchesObjectLabel("cup", 315, 0.79f, true))
        assertTrue(matchesObjectLabel("cup", 315, 0.80f, false))
        assertFalse(matchesObjectLabel("plant", 391, 1f, false))
    }

    @Test fun continuousConfirmationCompletesAfterThreeSeconds() {
        val progress = ObjectRecognitionProgress()
        for (now in 0L until 3_000L step 200L) assertTrue(progress.update(true, now) < 1f)
        assertEquals(1f, progress.update(true, 3_000L), 0.001f)
    }

    @Test fun briefSinkMissesPauseWithoutCreditingTheMissingTime() {
        val progress = ObjectRecognitionProgress()
        for (now in 0L..1_800L step 200L) progress.update(true, now, true)
        assertEquals(0.6f, progress.update(false, 2_000L, true), 0.001f)
        assertEquals(0.6f, progress.update(true, 2_200L, true), 0.001f)
        for (now in 2_400L..3_000L step 200L) progress.update(true, now, true)
        assertTrue(progress.update(true, 3_200L, true) < 1f)
        assertEquals(1f, progress.update(true, 3_400L, true), 0.001f)
    }

    @Test fun prolongedLossAndInferenceStallsResetSinkProgress() {
        val progress = ObjectRecognitionProgress()
        progress.update(true, 0, true)
        progress.update(true, 200, true)
        progress.update(false, 400, true)
        assertEquals(0f, progress.update(false, 801, true), 0f)
        assertFalse(progress.isTracking(801))
        progress.update(true, 1_000, true)
        progress.update(true, 1_200, true)
        assertEquals(0f, progress.update(true, 2_000, true), 0f)
    }

    @Test fun repeatedlyFlickeringFramesCannotComplete() {
        val progress = ObjectRecognitionProgress()
        for (i in 0..100) {
            assertEquals(0f, progress.update(i % 2 == 0, i * 200L, true), 0f)
        }
    }

    @Test fun cupStillResetsOnEveryMissAndResetClearsTracking() {
        val progress = ObjectRecognitionProgress()
        progress.update(true, 0)
        progress.update(true, 200)
        assertEquals(0f, progress.update(false, 400), 0f)
        progress.update(true, 600, true)
        assertTrue(progress.isTracking(600))
        progress.reset()
        assertFalse(progress.isTracking(600))
        assertEquals(0f, progress.update(true, 800, true), 0f)
    }

    @Test fun aFewSlowFramesCannotCompleteAndClockReversalResets() {
        val progress = ObjectRecognitionProgress()
        for (now in 0L..3_000L step 500L) assertTrue(progress.update(true, now) < 1f)
        assertEquals(0f, progress.update(true, 2_900L), 0f)
    }
}
