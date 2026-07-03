package dev.shreeman.nitro_camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the preview-transform math against the stretch regressions we hit:
 * after cover-cropping, the displayed aspect must equal the surface aspect for
 * EVERY sensor orientation / device size — otherwise the preview is stretched.
 */
class NitraFrameTransformTest {

    private val eps = 1e-3f

    private fun assertNoStretch(
        sensor: Int, cw: Int, ch: Int, sw: Int, sh: Int,
    ) {
        val displayed = NitraFrameTransform.displayedAspect(sensor, cw, ch, sw, sh)
        val surface = sw.toFloat() / sh
        assertEquals(
            "sensor=$sensor content=${cw}x$ch surface=${sw}x$sh → displayed aspect must match surface",
            surface, displayed, eps,
        )
    }

    @Test fun `portrait phone, 90 sensor, 16-9 camera — no stretch`() {
        assertNoStretch(sensor = 90, cw = 1920, ch = 1080, sw = 1080, sh = 2340)
    }

    @Test fun `portrait phone, 270 front sensor, 4-3 camera — no stretch`() {
        assertNoStretch(sensor = 270, cw = 4096, ch = 3072, sw = 1080, sh = 2340)
    }

    @Test fun `landscape surface, 90 sensor — no stretch`() {
        assertNoStretch(sensor = 90, cw = 1920, ch = 1080, sw = 1920, sh = 1080)
    }

    @Test fun `unrotated sensor 0 — no stretch`() {
        assertNoStretch(sensor = 0, cw = 1920, ch = 1080, sw = 1080, sh = 2340)
    }

    @Test fun `cover crop only shrinks one axis and stays within 0-1`() {
        val crop = NitraFrameTransform.coverCrop(90, 1920, 1080, 1080, 2340)
        val (cx, cy) = crop
        assertTrue("crop factors in (0,1]", cx > 0f && cx <= 1f && cy > 0f && cy <= 1f)
        assertTrue("exactly one axis is cropped", (cx < 1f) != (cy < 1f) || (cx == 1f && cy == 1f))
    }

    @Test fun `90 and 270 give the same crop (both rotate to portrait)`() {
        val a = NitraFrameTransform.coverCrop(90, 1920, 1080, 1080, 2340)
        val b = NitraFrameTransform.coverCrop(270, 1920, 1080, 1080, 2340)
        assertEquals(a[0], b[0], eps)
        assertEquals(a[1], b[1], eps)
    }

    @Test fun `cover crop factors stay within 0-1`() {
        for (s in intArrayOf(0, 90, 180, 270)) {
            val (cx, cy) = NitraFrameTransform.coverCrop(s, 4096, 3072, 1080, 2340)
            assertTrue("sensor=$s cropX in (0,1]", cx > 0f && cx <= 1f + eps)
            assertTrue("sensor=$s cropY in (0,1]", cy > 0f && cy <= 1f + eps)
        }
    }
}
