package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.RecordingOrientation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the recorded-video orientation/size math against the "squished +
 * sideways" regression: the GL renderer draws upright content, so a portrait
 * recording MUST get a tall surface — a landscape surface stretches it.
 */
class RecordingOrientationTest {

    // --- effectiveContent / isPortrait -------------------------------------

    @Test fun `back camera, typical 90 sensor`() {
        // Portrait device (display 0): sensor 90 -> content is portrait.
        assertEquals(90, RecordingOrientation.effectiveContent(90, 0, front = false))
        assertTrue(RecordingOrientation.isPortrait(90, 0, front = false))
        // Rotate device to landscape (display 90): content becomes landscape.
        assertEquals(0, RecordingOrientation.effectiveContent(90, 90, front = false))
        assertFalse(RecordingOrientation.isPortrait(90, 90, front = false))
        // display 0/180 are portrait (upright / upside-down), 90/270 landscape.
        assertTrue(RecordingOrientation.isPortrait(90, 180, front = false))
        assertFalse(RecordingOrientation.isPortrait(90, 270, front = false))
    }

    @Test fun `front camera mirrors the display rotation`() {
        // Front sensor typically 270: portrait in natural orientation.
        assertTrue(RecordingOrientation.isPortrait(270, 0, front = true))
        assertFalse(RecordingOrientation.isPortrait(270, 90, front = true))
        // Landscape-native sensor (tablet, 0): portrait when rotated.
        assertFalse(RecordingOrientation.isPortrait(0, 0, front = false))
        assertTrue(RecordingOrientation.isPortrait(0, 90, front = false))
    }

    @Test fun `orientation normalizes into 0-359`() {
        assertEquals(0, RecordingOrientation.effectiveContent(360, 0, front = false))
        assertEquals(90, RecordingOrientation.effectiveContent(90, 360, front = false))
    }

    // --- orientSize (the squish fix) ---------------------------------------

    @Test fun `portrait recording gets a TALL surface`() {
        // Encoder reports landscape 1920x1080; portrait content needs 1080x1920.
        val (w, h) = RecordingOrientation.orientSize(1920, 1080, portrait = true)
        assertEquals(1080, w)
        assertEquals(1920, h)
        assertTrue("portrait surface must be tall (w < h)", w < h)
    }

    @Test fun `landscape recording keeps a WIDE surface`() {
        val (w, h) = RecordingOrientation.orientSize(1920, 1080, portrait = false)
        assertEquals(1920, w)
        assertEquals(1080, h)
        assertTrue("landscape surface must be wide (w > h)", w > h)
    }

    @Test fun `input orientation does not matter — output follows portrait flag`() {
        // Even if the encoder size arrives already-tall, the flag decides.
        assertEquals(1080 to 1920, RecordingOrientation.orientSize(1080, 1920, portrait = true))
        assertEquals(1920 to 1080, RecordingOrientation.orientSize(1080, 1920, portrait = false))
    }

    @Test fun `odd dimensions are clamped even (H_264)`() {
        val (w, h) = RecordingOrientation.orientSize(1921, 1081, portrait = false)
        assertEquals(0, w % 2)
        assertEquals(0, h % 2)
        assertEquals(1920, w)
        assertEquals(1080, h)
    }
}
