package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.HighSpeedConfig
import dev.shreeman.nitro_camera.utils.HighSpeedConfig.Config
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards high-speed config selection against the real OnePlus CPH2447
 * capability set (1080p/720p @ 120 & 240, 4K @ 120).
 */
class HighSpeedConfigTest {
    private val configs = listOf(
        Config(3840, 2160, 30, 120),
        Config(1920, 1080, 30, 120),
        Config(1920, 1080, 120, 120),
        Config(1920, 1080, 30, 240),
        Config(1920, 1080, 240, 240),
        Config(1280, 720, 120, 120),
        Config(1280, 720, 240, 240),
    )

    @Test fun `1080p 120 picks the fixed 120 range, not the 30-120 one`() {
        val c = HighSpeedConfig.pick(configs, 1920, 1080, 120)!!
        assertEquals(1920, c.width)
        assertEquals(1080, c.height)
        assertEquals(120, c.fpsMin) // tightest range covering 120
        assertEquals(120, c.fpsMax)
    }

    @Test fun `1080p 240 picks the fixed 240 range`() {
        val c = HighSpeedConfig.pick(configs, 1920, 1080, 240)!!
        assertEquals(240, c.fpsMin)
        assertEquals(240, c.fpsMax)
    }

    @Test fun `720p 240 request matches the 720p config exactly`() {
        val c = HighSpeedConfig.pick(configs, 1280, 720, 240)!!
        assertEquals(1280, c.width)
        assertEquals(720, c.height)
        assertEquals(240, c.fpsMax)
    }

    @Test fun `unsupported fps returns null`() {
        assertNull(HighSpeedConfig.pick(configs, 1920, 1080, 480))
        assertNull(HighSpeedConfig.pick(emptyList(), 1920, 1080, 120))
    }

    @Test fun `off-size request falls back to the closest area that reaches the fps`() {
        // 1600x900 (1.44M px) is closer in area to 720p (0.92M) than 1080p (2.07M).
        val c = HighSpeedConfig.pick(configs, 1600, 900, 240)!!
        assertEquals(1280, c.width)
        assertEquals(720, c.height)
        // A near-1080p off-size request maps to 1080p.
        val big = HighSpeedConfig.pick(configs, 1900, 1060, 240)!!
        assertEquals(1920, big.width)
        assertEquals(1080, big.height)
    }

    @Test fun `isHighSpeed above 60`() {
        assertFalse(HighSpeedConfig.isHighSpeed(30))
        assertFalse(HighSpeedConfig.isHighSpeed(60))
        assertTrue(HighSpeedConfig.isHighSpeed(120))
        assertTrue(HighSpeedConfig.isHighSpeed(240))
    }
}
