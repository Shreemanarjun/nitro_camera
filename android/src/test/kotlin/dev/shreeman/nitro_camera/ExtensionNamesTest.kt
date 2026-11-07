package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.session.ExtensionNames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Camera extension names and size choice (CameraSession.setExtension). */
class ExtensionNamesTest {
    @Test
    fun namesRoundTripToCamera2Ids() {
        for (name in listOf("auto", "face-retouch", "bokeh", "hdr", "night")) {
            assertEquals(name, ExtensionNames.fromCamera2(ExtensionNames.toCamera2(name)!!))
        }
        assertEquals(4, ExtensionNames.toCamera2("night"))
        assertNull(ExtensionNames.toCamera2("portrait"))
    }

    @Test
    fun pickSizePrefersTheTargetAspectThenTheLargest() {
        val sizes = listOf(640 to 480, 1280 to 720, 1920 to 1080, 4000 to 3000)
        assertEquals(1920 to 1080, ExtensionNames.pickSize(sizes, 1080, 1920))
        assertEquals(4000 to 3000, ExtensionNames.pickSize(sizes, 3000, 4000))
    }

    @Test
    fun pickSizeHonoursThePixelCapUnlessNothingFits() {
        val sizes = listOf(1280 to 720, 1920 to 1080, 3840 to 2160)
        assertEquals(1920 to 1080, ExtensionNames.pickSize(sizes, 1920, 1080, 1920L * 1080))
        assertEquals(1280 to 720, ExtensionNames.pickSize(listOf(1280 to 720), 1920, 1080, 100))
        assertNull(ExtensionNames.pickSize(emptyList(), 1920, 1080))
    }
}
