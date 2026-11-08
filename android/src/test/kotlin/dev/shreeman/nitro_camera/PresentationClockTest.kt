package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.PresentationClock
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue

class PresentationClockTest {
    @Test
    fun rejectsZeroAndNonIncreasingTimesPerSurface() {
        val last = HashMap<Any, Long>()
        val a = Any()
        val b = Any()
        assertFalse("fresh SurfaceTexture time 0", PresentationClock.accept(last, a, 0L))
        assertTrue(PresentationClock.accept(last, a, 3_600_000_000_000L))
        assertFalse("duplicate", PresentationClock.accept(last, a, 3_600_000_000_000L))
        assertFalse("backwards", PresentationClock.accept(last, a, 1_000L))
        assertTrue(PresentationClock.accept(last, a, 3_600_033_000_000L))
        assertTrue("surfaces are independent", PresentationClock.accept(last, b, 1_000L))
    }

    @Test
    fun realtimeStampsMoveToTheMonotonicClock() {
        val sleep = 3_657_000_000_000L // an hour of deep sleep since boot
        val mono = 10_000_000_000_000L
        val real = mono + sleep
        // REALTIME-stamped frame 5 ms old → same age on the monotonic clock.
        assertEquals(mono - 5_000_000L, PresentationClock.toMonotonic(real - 5_000_000L, real, mono))
        // Already monotonic (timestampSource UNKNOWN) → unchanged.
        assertEquals(mono - 5_000_000L, PresentationClock.toMonotonic(mono - 5_000_000L, real, mono))
        // No sleep (emulator): both clocks agree → unchanged.
        assertEquals(mono - 1L, PresentationClock.toMonotonic(mono - 1L, mono, mono))
        assertEquals(0L, PresentationClock.toMonotonic(0L, real, mono))
    }
}
