package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.FocusMath
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Locks the normalized-focus → diopter mapping for LENS_FOCUS_DISTANCE. A wrong
 * row here means manual focus racks to the wrong plane.
 */
class FocusMathTest {

    @Test fun `far maps to 0 diopters, near maps to the device minimum`() {
        // minFocusDistance = 10 diopters (a 10cm macro lens).
        assertEquals(0f, FocusMath.diopters(0.0, 10f), 1e-4f)   // far / infinity
        assertEquals(10f, FocusMath.diopters(1.0, 10f), 1e-4f)  // nearest
        assertEquals(5f, FocusMath.diopters(0.5, 10f), 1e-4f)   // halfway
    }

    @Test fun `input is clamped to 0-1`() {
        assertEquals(0f, FocusMath.diopters(-2.0, 10f), 1e-4f)
        assertEquals(10f, FocusMath.diopters(5.0, 10f), 1e-4f)
    }

    @Test fun `fixed-focus lens (min 0) always returns 0`() {
        assertEquals(0f, FocusMath.diopters(0.5, 0f), 1e-4f)
        assertEquals(0f, FocusMath.diopters(1.0, 0f), 1e-4f)
    }
}
