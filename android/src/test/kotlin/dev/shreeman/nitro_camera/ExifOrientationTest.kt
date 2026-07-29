package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.ExifOrientation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the EXIF orientation (1-8) → (pending rotation, mirrored) mapping
 * reported on PhotoResult. A wrong row here means saved photos display
 * rotated or flipped in apps that honour the reported metadata.
 */
class ExifOrientationTest {

    @Test fun `all eight EXIF values decode to the spec rotation`() {
        assertEquals(0L, ExifOrientation.degrees(ExifOrientation.NORMAL))
        assertEquals(0L, ExifOrientation.degrees(ExifOrientation.FLIP_HORIZONTAL))
        assertEquals(180L, ExifOrientation.degrees(ExifOrientation.ROTATE_180))
        assertEquals(180L, ExifOrientation.degrees(ExifOrientation.FLIP_VERTICAL))
        assertEquals(90L, ExifOrientation.degrees(ExifOrientation.TRANSPOSE))
        assertEquals(90L, ExifOrientation.degrees(ExifOrientation.ROTATE_90))
        assertEquals(270L, ExifOrientation.degrees(ExifOrientation.TRANSVERSE))
        assertEquals(270L, ExifOrientation.degrees(ExifOrientation.ROTATE_270))
    }

    @Test fun `only the four flip variants are mirrored`() {
        assertFalse(ExifOrientation.mirrored(ExifOrientation.NORMAL))
        assertFalse(ExifOrientation.mirrored(ExifOrientation.ROTATE_90))
        assertFalse(ExifOrientation.mirrored(ExifOrientation.ROTATE_180))
        assertFalse(ExifOrientation.mirrored(ExifOrientation.ROTATE_270))
        assertTrue(ExifOrientation.mirrored(ExifOrientation.FLIP_HORIZONTAL))
        assertTrue(ExifOrientation.mirrored(ExifOrientation.FLIP_VERTICAL))
        assertTrue(ExifOrientation.mirrored(ExifOrientation.TRANSPOSE))
        assertTrue(ExifOrientation.mirrored(ExifOrientation.TRANSVERSE))
    }

    @Test fun `undefined and out-of-range tags decode to upright unmirrored`() {
        for (tag in intArrayOf(0, -1, 9, 42)) {
            assertEquals("tag=$tag", 0L, ExifOrientation.degrees(tag))
            assertFalse("tag=$tag", ExifOrientation.mirrored(tag))
        }
    }

    @Test fun `constants match the EXIF spec values`() {
        // These must equal android.media.ExifInterface.ORIENTATION_* (which are
        // themselves the EXIF spec numbers) — PhotoOutput reads the tag with
        // ExifInterface and decodes it with this table.
        assertEquals(1, ExifOrientation.NORMAL)
        assertEquals(2, ExifOrientation.FLIP_HORIZONTAL)
        assertEquals(3, ExifOrientation.ROTATE_180)
        assertEquals(4, ExifOrientation.FLIP_VERTICAL)
        assertEquals(5, ExifOrientation.TRANSPOSE)
        assertEquals(6, ExifOrientation.ROTATE_90)
        assertEquals(7, ExifOrientation.TRANSVERSE)
        assertEquals(8, ExifOrientation.ROTATE_270)
    }
}
