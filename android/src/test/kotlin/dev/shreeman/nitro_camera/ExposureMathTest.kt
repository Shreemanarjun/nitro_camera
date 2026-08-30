package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.ExposureMath
import org.junit.Assert.assertEquals
import org.junit.Test

/** Guards manual ISO/shutter clamping to the device's sensor ranges. */
class ExposureMathTest {
    @Test fun `iso clamps and rounds into the sensitivity range`() {
        assertEquals(100, ExposureMath.clampIso(50.0, 100, 3200))    // below min
        assertEquals(3200, ExposureMath.clampIso(6400.0, 100, 3200)) // above max
        assertEquals(801, ExposureMath.clampIso(800.6, 100, 3200))   // rounds
    }

    @Test fun `exposure time clamps into the nanosecond range`() {
        // range 1/8000s .. 1/4s in ns.
        val min = 125_000L
        val max = 250_000_000L
        assertEquals(min, ExposureMath.clampExposureNanos(1000.0, min, max))          // too fast
        assertEquals(max, ExposureMath.clampExposureNanos(1_000_000_000.0, min, max)) // too slow
        assertEquals(20_000_000L, ExposureMath.clampExposureNanos(20_000_000.0, min, max)) // 1/50s ok
    }
}
